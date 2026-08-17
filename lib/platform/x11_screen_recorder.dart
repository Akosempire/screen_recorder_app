import '../models/display_server.dart';
import '../services/ffmpeg_process_manager.dart';
import '../services/ffmpeg_recorder.dart';

class X11ScreenRecorder extends SegmentingScreenRecorder {
  X11ScreenRecorder({
    required String display,
    required super.encoder,
    super.processManager,
    super.runner,
  }) : super(
          backendName: 'X11 / FFmpeg x11grab',
          stopStyle: StopStyle.ffmpegQuit,
          commandBuilder: (region, outputPath) => CaptureCommand(
            'ffmpeg',
            buildX11GrabArgs(
              region: region,
              display: display,
              outputPath: outputPath,
              encoder: encoder,
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
      runner: runner,
    );
  }
}
