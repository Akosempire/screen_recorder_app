import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/display_server.dart';
import 'app_logger.dart';
import 'ffmpeg_binary.dart';
import 'ffmpeg_process_manager.dart';
import 'linux_desktop.dart';
import 'xdg_portal_screenshot.dart';

export 'xdg_portal_screenshot.dart' show PortalCaptureResult, PortalCaptureStatus;

/// Captures a still of the desktop so the region overlay can dim a real image
/// without depending on GTK window transparency.
class DesktopSnapshotService {
  DesktopSnapshotService({
    ProcessRunner runner = const ProcessRunner(),
    Future<PortalCaptureResult> Function(
      File destination, {
      String parentWindow,
      Duration timeout,
    })? portalCapture,
    bool Function()? isGnomeDesktop,
  })  : _runner = runner,
        _portalCapture = portalCapture ??
            ((file, {parentWindow = '', timeout = const Duration(seconds: 45)}) =>
                XdgPortalScreenshot().captureTo(
                  file,
                  parentWindow: parentWindow,
                  timeout: timeout,
                )),
        _isGnomeDesktop = isGnomeDesktop ?? (() => LinuxDesktop.isGnome);

  final ProcessRunner _runner;
  final Future<PortalCaptureResult> Function(
    File destination, {
    String parentWindow,
    Duration timeout,
  }) _portalCapture;
  final bool Function() _isGnomeDesktop;
  int _snapSeq = 0;

  File _newSnapshotFile() {
    _snapSeq += 1;
    return File(
      p.join(
        Directory.systemTemp.path,
        'screen_recorder_snap_${DateTime.now().microsecondsSinceEpoch}_$_snapSeq.png',
      ),
    );
  }

  /// Portal-only still. GNOME Wayland must use this, never [capture], so a
  /// cancelled portal cannot fall through to gnome-screenshot / grim / D-Bus.
  Future<PortalCaptureResult> capturePortal(
    DesktopGeometry geometry, {
    required String parentWindow,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final file = _newSnapshotFile();
    try {
      return await _portalCapture(
        file,
        parentWindow: parentWindow,
        timeout: timeout,
      );
    } catch (error, stack) {
      AppLogger.warn('XDG screenshot portal unavailable: $error\n$stack');
      return const PortalCaptureResult(PortalCaptureStatus.failed);
    }
  }

  Future<File?> capture(
    DesktopGeometry geometry, {
    String parentWindow = '',
  }) async {
    final file = _newSnapshotFile();

    if (geometry.displayServer == DisplayServer.windows) {
      return _tryFfmpegGdigrab(file, geometry);
    }

    if (geometry.displayServer == DisplayServer.wayland) {
      // x11grab on Wayland captures the XWayland root, which is typically
      // a black screen. Never use it for the overlay on Wayland.
      if (!_isGnomeDesktop()) {
        final grim = await _tryGrim(file);
        if (grim != null) {
          return grim;
        }
      }

      final portal = await _tryPortal(file, parentWindow: parentWindow);
      if (portal != null) {
        return portal;
      }

      // Never start a GNOME Screencast for a still. The service stops as
      // soon as a one-shot gdbus caller disconnects, which shows
      // "Screencast ended unexpectedly" and can poison the later recording.

      final gnomeCli = await _tryGnomeScreenshot(file);
      if (gnomeCli != null) {
        return gnomeCli;
      }
      final gnomeDbus = await _tryGnomeScreenshotDbus(file);
      if (gnomeDbus != null) {
        return gnomeDbus;
      }
      final gnomeArea = await _tryGnomeScreenshotArea(file, geometry);
      if (gnomeArea != null) {
        return gnomeArea;
      }
      final grim = await _tryGrim(file);
      if (grim != null) {
        return grim;
      }
      AppLogger.warn(
        'Wayland desktop snapshot failed; overlay will dim a transparent window',
      );
      return null;
    }

    final ffmpeg = await _tryFfmpegX11(file, geometry);
    if (ffmpeg != null) {
      return ffmpeg;
    }

    final magick = await _tryImageMagick(file);
    if (magick != null) {
      return magick;
    }

    final portal = await _tryPortal(file, parentWindow: parentWindow);
    if (portal != null) {
      return portal;
    }

    final gnome = await _tryGnomeScreenshot(file);
    if (gnome != null) {
      return gnome;
    }

    AppLogger.warn('Desktop snapshot failed; overlay will use a dim fill');
    return null;
  }

  Future<File?> _tryPortal(File file, {String parentWindow = ''}) async {
    try {
      final result = await _portalCapture(
        file,
        parentWindow: parentWindow,
        timeout: const Duration(seconds: 45),
      );
      return result.file;
    } catch (error, stack) {
      AppLogger.warn('XDG screenshot portal unavailable: $error\n$stack');
      return null;
    }
  }

  Future<File?> _tryGrim(File file) async {
    try {
      final result = await _runner.run(
        'grim',
        [file.path],
        timeout: const Duration(seconds: 4),
      );
      if (result.exitCode == 0 && await _usable(file)) {
        AppLogger.info('Snapshot via grim: ${file.path}');
        return file;
      }
      AppLogger.debug('grim snapshot failed: ${result.stderr}');
    } on ProcessException catch (error) {
      AppLogger.debug('grim unavailable: $error');
    } on TimeoutException catch (error) {
      AppLogger.debug('grim timed out: $error');
    }
    return null;
  }

  Future<File?> _tryFfmpegX11(File file, DesktopGeometry geometry) async {
    final display = geometry.displayName ?? Platform.environment['DISPLAY'];
    if (display == null || display.isEmpty || geometry.width <= 0) {
      return null;
    }
    try {
      final result = await _runner.run(
        'ffmpeg',
        [
          '-y',
          '-f',
          'x11grab',
          '-video_size',
          '${geometry.width}x${geometry.height}',
          '-i',
          '$display+${geometry.minX},${geometry.minY}',
          '-frames:v',
          '1',
          file.path,
        ],
        timeout: const Duration(seconds: 8),
      );
      if (result.exitCode == 0 && await _usable(file)) {
        AppLogger.info('Snapshot via ffmpeg x11grab: ${file.path}');
        return file;
      }
      AppLogger.debug('ffmpeg snapshot failed: ${result.stderr}');
    } on ProcessException catch (error) {
      AppLogger.debug('ffmpeg snapshot unavailable: $error');
    } on TimeoutException catch (error) {
      AppLogger.debug('ffmpeg snapshot timed out: $error');
    }
    return null;
  }

  Future<File?> _tryFfmpegGdigrab(File file, DesktopGeometry geometry) async {
    try {
      final result = await _runner.run(
        ffmpegExecutable,
        [
          '-y',
          '-hide_banner',
          '-f',
          'gdigrab',
          '-draw_mouse',
          '0',
          '-offset_x',
          '${geometry.minX}',
          '-offset_y',
          '${geometry.minY}',
          '-video_size',
          '${geometry.width}x${geometry.height}',
          '-i',
          'desktop',
          '-frames:v',
          '1',
          file.path,
        ],
        timeout: const Duration(seconds: 8),
      );
      if (result.exitCode == 0 && await _usable(file)) {
        AppLogger.info('Snapshot via ffmpeg gdigrab: ${file.path}');
        return file;
      }
      AppLogger.warn('gdigrab snapshot failed: ${result.stderr}');
    } on ProcessException catch (error) {
      AppLogger.debug('ffmpeg snapshot unavailable: $error');
    } on TimeoutException catch (error) {
      AppLogger.debug('ffmpeg snapshot timed out: $error');
    }
    return null;
  }

  Future<File?> _tryImageMagick(File file) async {
    try {
      final result = await _runner.run(
        'import',
        ['-window', 'root', file.path],
        timeout: const Duration(seconds: 4),
      );
      if (result.exitCode == 0 && await _usable(file)) {
        AppLogger.info('Snapshot via ImageMagick import: ${file.path}');
        return file;
      }
    } on ProcessException catch (error) {
      AppLogger.debug('import unavailable: $error');
    } on TimeoutException catch (error) {
      AppLogger.debug('import timed out: $error');
    }
    return null;
  }

  Future<File?> _tryGnomeScreenshot(File file) async {
    try {
      final result = await _runner.run(
        'gnome-screenshot',
        ['-f', file.path],
        timeout: const Duration(seconds: 4),
      );
      if (result.exitCode == 0 && await _usable(file)) {
        AppLogger.info('Snapshot via gnome-screenshot: ${file.path}');
        return file;
      }
      AppLogger.debug(
        'gnome-screenshot failed: ${result.stdout} ${result.stderr}',
      );
    } on ProcessException catch (error) {
      AppLogger.debug('gnome-screenshot unavailable: $error');
    } on TimeoutException catch (error) {
      AppLogger.debug('gnome-screenshot timed out: $error');
    }
    return null;
  }

  Future<File?> _tryGnomeScreenshotDbus(File file) async {
    try {
      final result = await _runner.run(
        'gdbus',
        buildGnomeScreenshotArgs(file.path),
        timeout: const Duration(seconds: 4),
      );
      final snap = await _fileFromGdbus(result, file);
      if (snap != null) {
        AppLogger.info('Snapshot via GNOME Screenshot D-Bus: ${snap.path}');
        return snap;
      }
      AppLogger.debug(
        'GNOME Screenshot D-Bus failed: ${result.stdout} ${result.stderr}',
      );
    } on ProcessException catch (error) {
      AppLogger.debug('GNOME Screenshot D-Bus unavailable: $error');
    } on TimeoutException catch (error) {
      AppLogger.debug('GNOME Screenshot D-Bus timed out: $error');
    }
    return null;
  }

  Future<File?> _tryGnomeScreenshotArea(
    File file,
    DesktopGeometry geometry,
  ) async {
    try {
      final result = await _runner.run(
        'gdbus',
        buildGnomeScreenshotAreaArgs(
          x: geometry.minX,
          y: geometry.minY,
          width: geometry.width,
          height: geometry.height,
          outputPath: file.path,
        ),
        timeout: const Duration(seconds: 4),
      );
      final snap = await _fileFromGdbus(result, file);
      if (snap != null) {
        AppLogger.info('Snapshot via GNOME ScreenshotArea: ${snap.path}');
        return snap;
      }
    } on ProcessException catch (error) {
      AppLogger.debug('GNOME ScreenshotArea unavailable: $error');
    } on TimeoutException catch (error) {
      AppLogger.debug('GNOME ScreenshotArea timed out: $error');
    }
    return null;
  }

  Future<File?> _fileFromGdbus(ProcessResult result, File fallback) async {
    if (result.exitCode != 0 || !parseGdbusBoolean(result.stdout.toString())) {
      return null;
    }
    final returned = parseGdbusSuccessPath(result.stdout.toString());
    final snap =
        returned == null || returned.isEmpty ? fallback : File(returned);
    if (await _usable(snap)) {
      return snap;
    }
    return null;
  }

  Future<bool> _usable(File file) async {
    return await file.exists() && await file.length() > 64;
  }
}
