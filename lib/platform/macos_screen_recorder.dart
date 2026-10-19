import '../models/recorder_exception.dart';
import '../models/screen_region.dart';
import '../services/app_logger.dart';
import '../services/cursor_tracker.dart';
import '../services/enhanced_recorder.dart';
import '../services/ffmpeg_binary.dart';
import '../services/ffmpeg_process_manager.dart';
import '../services/ffmpeg_recorder.dart';
import '../services/recording_options.dart';
import 'cursor_input.dart';

/// macOS backend: FFmpeg `avfoundation` captures the main display (and the
/// default microphone), cropped to the selected region. The cursor halo and
/// face bubble are on-screen windows (macos/Runner), so they're recorded as
/// seen; CoreGraphics cursor tracking drives auto-zoom.
class MacScreenRecorder extends EnhancedScreenRecorder {
  MacScreenRecorder({
    required super.encoder,
    required this.screenIndex,
    this.microphoneIndex,
    double scale = 1,
    super.processManager,
    super.runner,
    CursorTracker? tracker,
    super.overlay,
    RecordingOptions? options,
  }) : super(
          backendName: 'macOS / FFmpeg avfoundation',
          stopStyle: StopStyle.ffmpegQuit,
          tracker: tracker ??
              CursorTracker(input: platformCursorInput(macScale: scale)),
          options: options,
          commandBuilder: (region, outputPath, recordMicrophone) =>
              CaptureCommand(
            ffmpegExecutable,
            buildAvfoundationArgs(
              region: region,
              outputPath: outputPath,
              encoder: encoder,
              screenIndex: screenIndex,
              microphoneIndex: recordMicrophone ? microphoneIndex : null,
              // The app's own halo and ripples are drawn live on screen.
              clicks: false,
            ),
          ),
        );

  /// avfoundation video device index of "Capture screen 0".
  final int screenIndex;

  /// avfoundation audio device index, or null if there's no microphone.
  final int? microphoneIndex;

  static Future<MacScreenRecorder> create({
    required String encoder,
    required double scale,
    ProcessRunner runner = const ProcessRunner(),
  }) async {
    final devices = await listAvfoundationDevices(runner);
    AppLogger.info(
      'avfoundation screens: ${devices.screens}, microphones: ${devices.microphones}',
    );
    if (devices.screens.isEmpty) {
      // Usually the Screen Recording permission: without it macOS hides the
      // screen devices from FFmpeg.
      MacScreenAccess.request();
      throw const RecorderException(
        userMessage: macPermissionMessage,
        technicalDetails: 'avfoundation listed no "Capture screen" devices',
      );
    }
    return MacScreenRecorder(
      encoder: encoder,
      screenIndex: devices.screens.first.index,
      microphoneIndex:
          devices.microphones.isEmpty ? null : devices.microphones.first.index,
      scale: scale,
      runner: runner,
    );
  }

  @override
  Future<void> start(
    ScreenRegion region, {
    bool recordMicrophone = false,
  }) async {
    if (!MacScreenAccess.granted) {
      MacScreenAccess.request();
      throw const RecorderException(userMessage: macPermissionMessage);
    }
    if (recordMicrophone && microphoneIndex == null) {
      throw const RecorderException(
        userMessage:
            'No microphone was found. Plug one in or turn the microphone switch off.',
      );
    }
    await super.start(region, recordMicrophone: recordMicrophone);
  }
}

const macPermissionMessage =
    'Screen Recorder needs permission to record your screen. '
    'Open System Settings → Privacy & Security → Screen Recording, '
    'turn on Screen Recorder, then quit and reopen the app.';

class AvDevice {
  const AvDevice(this.index, this.name);

  final int index;
  final String name;

  @override
  String toString() => '[$index] $name';
}

class AvDevices {
  const AvDevices(this.screens, this.cameras, this.microphones);

  final List<AvDevice> screens;
  final List<AvDevice> cameras;
  final List<AvDevice> microphones;
}

Future<AvDevices> listAvfoundationDevices(ProcessRunner runner) async {
  try {
    final result = await runner.run(
      ffmpegExecutable,
      const ['-hide_banner', '-f', 'avfoundation', '-list_devices', 'true', '-i', ''],
      timeout: const Duration(seconds: 8),
    );
    return parseAvfoundationDevices('${result.stderr}\n${result.stdout}');
  } catch (error) {
    AppLogger.debug('avfoundation device listing failed: $error');
    return const AvDevices([], [], []);
  }
}

/// Parses `ffmpeg -f avfoundation -list_devices true -i ""`:
/// ```
/// [AVFoundation indev @ 0x…] AVFoundation video devices:
/// [AVFoundation indev @ 0x…] [0] FaceTime HD Camera
/// [AVFoundation indev @ 0x…] [1] Capture screen 0
/// [AVFoundation indev @ 0x…] AVFoundation audio devices:
/// [AVFoundation indev @ 0x…] [0] MacBook Pro Microphone
/// ```
AvDevices parseAvfoundationDevices(String output) {
  final screens = <AvDevice>[];
  final cameras = <AvDevice>[];
  final mics = <AvDevice>[];
  var section = '';
  final entry = RegExp(r'\]\s+\[(\d+)\]\s+(.+?)\s*$');
  for (final line in output.split('\n')) {
    if (line.contains('AVFoundation video devices')) {
      section = 'video';
      continue;
    }
    if (line.contains('AVFoundation audio devices')) {
      section = 'audio';
      continue;
    }
    final match = entry.firstMatch(line);
    if (match == null) continue;
    final device = AvDevice(int.parse(match.group(1)!), match.group(2)!);
    if (section == 'video') {
      if (device.name.startsWith('Capture screen')) {
        screens.add(device);
      } else {
        cameras.add(device);
      }
    } else if (section == 'audio') {
      mics.add(device);
    }
  }
  return AvDevices(screens, cameras, mics);
}

/// FFmpeg arguments for an avfoundation capture of [region] (main-display
/// pixels) from screen device [screenIndex].
List<String> buildAvfoundationArgs({
  required ScreenRegion region,
  required String outputPath,
  required String encoder,
  required int screenIndex,
  int? microphoneIndex,
  bool clicks = true,
  int fps = 30,
}) {
  final aligned = region.evenAligned();
  return [
    '-y',
    '-hide_banner',
    '-f',
    'avfoundation',
    '-thread_queue_size',
    '512',
    '-framerate',
    '$fps',
    '-capture_cursor',
    '1',
    '-capture_mouse_clicks',
    clicks ? '1' : '0',
    '-i',
    '$screenIndex:${microphoneIndex ?? 'none'}',
    '-vf',
    'crop=${aligned.width}:${aligned.height}:${aligned.x}:${aligned.y},fps=$fps',
    ...ffmpegEncodeArgs(
      encoder: encoder,
      outputPath: outputPath,
      recordMicrophone: microphoneIndex != null,
    ),
  ];
}
