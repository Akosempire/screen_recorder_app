import 'dart:io';

import '../models/recorder_exception.dart';
import '../models/screen_region.dart';
import '../services/app_logger.dart';
import '../services/enhanced_recorder.dart';
import '../services/ffmpeg_binary.dart';
import '../services/ffmpeg_process_manager.dart';
import '../services/ffmpeg_recorder.dart';

/// Windows backend: FFmpeg `gdigrab` for video, DirectShow for the mic,
/// plus the live cursor highlight overlay and post-recording auto-zoom.
class WindowsScreenRecorder extends EnhancedScreenRecorder {
  WindowsScreenRecorder({
    required super.encoder,
    this.microphoneDevice,
    super.processManager,
    super.runner,
    super.tracker,
    super.overlay,
    super.options,
  }) : super(
          backendName: 'Windows / FFmpeg gdigrab',
          stopStyle: StopStyle.ffmpegQuit,
          commandBuilder: (region, outputPath, recordMicrophone) =>
              CaptureCommand(
            ffmpegExecutable,
            buildGdigrabArgs(
              region: region,
              outputPath: outputPath,
              encoder: encoder,
              microphoneDevice: recordMicrophone ? microphoneDevice : null,
            ),
          ),
        );

  /// DirectShow audio device name, or null if none was found.
  final String? microphoneDevice;

  static Future<WindowsScreenRecorder> create({
    required String encoder,
    ProcessRunner runner = const ProcessRunner(),
  }) async {
    final mic = await findDshowMicrophone(runner);
    AppLogger.info('DirectShow microphone: ${mic ?? '(none)'}');
    return WindowsScreenRecorder(
      encoder: encoder,
      microphoneDevice: mic,
      runner: runner,
    );
  }

  @override
  Future<void> start(
    ScreenRegion region, {
    bool recordMicrophone = false,
  }) async {
    if (recordMicrophone && microphoneDevice == null) {
      throw const RecorderException(
        userMessage:
            'No microphone was found. Plug one in or turn the microphone switch off.',
      );
    }
    await super.start(region, recordMicrophone: recordMicrophone);
  }
}

/// FFmpeg arguments for a gdigrab region capture.
///
/// Offsets and size are physical pixels on the virtual desktop (they can be
/// negative for monitors left of / above the primary).
List<String> buildGdigrabArgs({
  required ScreenRegion region,
  required String outputPath,
  required String encoder,
  String? microphoneDevice,
  int fps = 30,
}) {
  final aligned = region.evenAligned();
  return [
    '-y',
    '-hide_banner',
    '-f',
    'gdigrab',
    '-thread_queue_size',
    '512',
    '-framerate',
    '$fps',
    '-draw_mouse',
    '1',
    '-offset_x',
    '${aligned.x}',
    '-offset_y',
    '${aligned.y}',
    '-video_size',
    '${aligned.width}x${aligned.height}',
    '-i',
    'desktop',
    if (microphoneDevice != null) ...[
      '-f',
      'dshow',
      '-thread_queue_size',
      '512',
      '-rtbufsize',
      '64M',
      '-i',
      'audio=$microphoneDevice',
    ],
    ...ffmpegEncodeArgs(
      encoder: encoder,
      outputPath: outputPath,
      recordMicrophone: microphoneDevice != null,
    ),
  ];
}

/// First DirectShow audio capture device, e.g. `Microphone (Realtek Audio)`.
Future<String?> findDshowMicrophone(ProcessRunner runner) async {
  if (!Platform.isWindows) return null;
  try {
    final result = await runner.run(
      ffmpegExecutable,
      const ['-hide_banner', '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'],
      timeout: const Duration(seconds: 8),
    );
    return parseDshowAudioDevices('${result.stderr}\n${result.stdout}')
        .firstOrNull;
  } catch (error) {
    AppLogger.debug('dshow device listing failed: $error');
    return null;
  }
}

/// Parses `ffmpeg -list_devices true -f dshow -i dummy` output (both the
/// modern `"Name" (audio)` format and the older sectioned format).
List<String> parseDshowAudioDevices(String output) {
  final devices = <String>[];
  final modern = RegExp(r'"([^"]+)"\s+\(audio\)');
  for (final match in modern.allMatches(output)) {
    devices.add(match.group(1)!);
  }
  if (devices.isNotEmpty) return devices;

  var inAudio = false;
  final quoted = RegExp(r'\]\s+"([^"]+)"');
  for (final line in output.split('\n')) {
    if (line.contains('DirectShow audio devices')) {
      inAudio = true;
      continue;
    }
    if (line.contains('DirectShow video devices')) {
      inAudio = false;
      continue;
    }
    if (!inAudio || line.contains('Alternative name')) continue;
    final match = quoted.firstMatch(line);
    if (match != null) devices.add(match.group(1)!);
  }
  return devices;
}
