import 'dart:io';

import '../models/display_server.dart';
import '../models/recorder_exception.dart';
import '../platform/wayland_screen_recorder.dart';
import '../platform/windows_screen_recorder.dart';
import '../platform/x11_screen_recorder.dart';
import 'app_logger.dart';
import 'ffmpeg_process_manager.dart';
import 'linux_desktop.dart';
import 'linux_screen_service.dart';
import 'screen_recorder.dart';
import 'windows_screen_service.dart';

class ScreenRecorderFactory {
  ScreenRecorderFactory({
    LinuxScreenService? linuxScreen,
    FfmpegProbe? probe,
    ProcessRunner? runner,
  })  : _linuxScreen = linuxScreen ?? LinuxScreenService(runner: runner ?? const ProcessRunner()),
        _probe = probe ?? FfmpegProbe(runner: runner ?? const ProcessRunner()),
        _runner = runner ?? const ProcessRunner();

  final LinuxScreenService _linuxScreen;
  final FfmpegProbe _probe;
  final ProcessRunner _runner;

  Future<CreatedRecorder> create() async {
    final ffmpegOk = await _probe.isAvailable();
    if (!ffmpegOk) {
      throw RecorderException(
        userMessage: Platform.isWindows
            ? 'FFmpeg is missing from the app folder. Reinstall Screen Recorder.'
            : 'FFmpeg is not installed or is not on PATH. '
                'Install it with: sudo apt install ffmpeg',
        technicalDetails: 'ffmpeg -version failed',
      );
    }

    final geometry = Platform.isWindows
        ? await const WindowsScreenService().queryGeometry()
        : await _linuxScreen.queryGeometry();
    if (geometry.isEmpty) {
      throw const RecorderException(
        userMessage: 'No monitors were detected.',
      );
    }

    final encoder = await _probe.preferredVideoEncoder();
    AppLogger.info(
      'Display server: ${geometry.displayServer.name}, '
      'desktop: ${LinuxDesktop.currentDesktop}, encoder: $encoder',
    );

    switch (geometry.displayServer) {
      case DisplayServer.x11:
        return CreatedRecorder(
          recorder: X11ScreenRecorder.fromGeometry(
            geometry,
            encoder: encoder,
            runner: _runner,
          ),
          geometry: geometry,
          encoder: encoder,
        );
      case DisplayServer.wayland:
        return CreatedRecorder(
          recorder: await WaylandScreenRecorder.create(
            geometry: geometry,
            encoder: encoder,
            runner: _runner,
          ),
          geometry: geometry,
          encoder: encoder,
        );
      case DisplayServer.windows:
        return CreatedRecorder(
          recorder: await WindowsScreenRecorder.create(
            encoder: encoder,
            runner: _runner,
          ),
          geometry: geometry,
          encoder: encoder,
        );
      case DisplayServer.unknown:
        throw const RecorderException(
          userMessage:
              'Could not detect whether this session is X11 or Wayland. '
              'Set XDG_SESSION_TYPE or run from a graphical session.',
        );
    }
  }
}

class CreatedRecorder {
  final ScreenRecorder recorder;
  final DesktopGeometry geometry;
  final String encoder;

  const CreatedRecorder({
    required this.recorder,
    required this.geometry,
    required this.encoder,
  });
}
