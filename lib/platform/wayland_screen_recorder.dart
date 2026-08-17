import '../models/display_server.dart';
import '../models/recorder_exception.dart';
import '../services/app_logger.dart';
import '../services/ffmpeg_process_manager.dart';
import '../services/ffmpeg_recorder.dart';
import '../services/linux_desktop.dart';
import '../services/screen_recorder.dart';
import 'gnome_shell_screen_recorder.dart';

/// Wayland capture backend.
///
/// * GNOME: `org.gnome.Shell.Screencast.ScreencastArea`
/// * wlroots (Sway, Hyprland, …): `wf-recorder -g`
/// * GNOME/KDE do not implement wlr-screencopy, so wf-recorder is not used there.
class WaylandScreenRecorder extends SegmentingScreenRecorder {
  WaylandScreenRecorder({
    required super.encoder,
    super.processManager,
    super.runner,
  }) : super(
          backendName: 'Wayland / wf-recorder',
          stopStyle: StopStyle.sigint,
          commandBuilder: (region, outputPath) => CaptureCommand(
            'wf-recorder',
            buildWfRecorderArgs(region: region, outputPath: outputPath),
          ),
        );

  static Future<ScreenRecorder> create({
    required DesktopGeometry geometry,
    required String encoder,
    ProcessRunner runner = const ProcessRunner(),
    CaptureProcessManager? processManager,
  }) async {
    if (await GnomeShellScreenRecorder.isAvailable(runner: runner)) {
      AppLogger.info(
        'Using GNOME Shell ScreencastArea backend '
        '(${geometry.width}x${geometry.height})',
      );
      return GnomeShellScreenRecorder(runner: runner, encoder: encoder);
    }

    final hasWfRecorder = await runner.hasBinary('wf-recorder');
    if (hasWfRecorder &&
        (LinuxDesktop.isWlroots || (!LinuxDesktop.isGnome && !LinuxDesktop.isKde))) {
      AppLogger.info('Using wf-recorder backend');
      return WaylandScreenRecorder(
        encoder: encoder,
        processManager: processManager,
        runner: runner,
      );
    }

    if (LinuxDesktop.isGnome) {
      throw const RecorderException(
        userMessage:
            'GNOME Wayland recording needs the GNOME screencast service '
            '(org.gnome.Shell.Screencast). It was not available. '
            'Try an X11 GNOME session, or check that screen recording is allowed.',
        technicalDetails: 'GNOME detected, Screencast D-Bus name missing',
      );
    }

    if (hasWfRecorder && LinuxDesktop.isKde) {
      throw const RecorderException(
        userMessage:
            'KDE Plasma on Wayland cannot use wf-recorder (no wlr-screencopy). '
            'Use a Plasma X11 session, or a wlroots compositor such as Sway.',
        technicalDetails: 'KDE Wayland, wf-recorder present but unsupported',
      );
    }

    throw const RecorderException(
      userMessage:
          'No Wayland region recorder is available. On GNOME this app uses the '
          'built-in screencast service. On Sway/Hyprland install wf-recorder. '
          'GNOME/KDE Wayland cannot use FFmpeg x11grab for native windows.',
      technicalDetails: 'No GNOME Screencast and no usable wf-recorder',
    );
  }
}
