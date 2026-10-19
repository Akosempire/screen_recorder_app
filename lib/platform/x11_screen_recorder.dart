import '../models/display_server.dart';
import '../services/enhanced_recorder.dart';
import '../services/ffmpeg_binary.dart';
import '../services/ffmpeg_process_manager.dart';
import '../services/ffmpeg_recorder.dart';

/// Linux X11 backend: FFmpeg `x11grab` + PulseAudio mic, with cursor
/// tracking (libX11) for auto-zoom.
class X11ScreenRecorder extends EnhancedScreenRecorder {
  X11ScreenRecorder({
    required String display,
    required super.encoder,
    super.processManager,
    super.runner,
    super.tracker,
    super.overlay,
    super.options,
  }) : super(
          backendName: 'X11 / FFmpeg x11grab',
          stopStyle: StopStyle.ffmpegQuit,
          commandBuilder: (region, outputPath, recordMicrophone) =>
              CaptureCommand(
            ffmpegExecutable,
            buildX11GrabArgs(
              region: region,
              display: display,
              outputPath: outputPath,
              encoder: encoder,
              recordMicrophone: recordMicrophone,
            ),
          ),
        );

  factory X11ScreenRecorder.fromGeometry(
    DesktopGeometry geometry, {
    required String encoder,
    CaptureProcessManager? processManager,
    ProcessRunner? runner,
  }) {
    final display = geometry.displayName ?? ':0.0';
    return X11ScreenRecorder(
      display: display,
      encoder: encoder,
      processManager: processManager,
      runner: runner ?? const ProcessRunner(),
    );
  }
}
