import 'dart:io';

import '../models/recorder_exception.dart';
import '../models/screen_region.dart';
import '../services/app_logger.dart';
import '../services/auto_zoom.dart';
import '../services/camera_bubble.dart';
import '../services/cursor_overlay.dart';
import '../services/cursor_tracker.dart';
import '../services/ffmpeg_binary.dart';
import '../services/ffmpeg_process_manager.dart';
import '../services/ffmpeg_recorder.dart';
import '../services/recording_library.dart';
import '../services/recording_options.dart';

/// Windows backend: FFmpeg `gdigrab` for video, DirectShow for the mic,
/// plus the live cursor highlight overlay and post-recording auto-zoom.
class WindowsScreenRecorder extends SegmentingScreenRecorder {
  WindowsScreenRecorder({
    required super.encoder,
    this.microphoneDevice,
    super.processManager,
    ProcessRunner runner = const ProcessRunner(),
    CursorTracker? tracker,
    CursorOverlay? overlay,
    RecordingOptions? options,
  })  : _zoomRunner = runner,
        _tracker = tracker ?? CursorTracker(),
        _overlay = overlay ?? CursorOverlay(),
        _options = options ?? RecordingOptions.instance,
        super(
          runner: runner,
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

  final ProcessRunner _zoomRunner;
  final CursorTracker _tracker;
  final CursorOverlay _overlay;
  final RecordingOptions _options;

  ScreenRegion? _activeRegion;
  bool _activeMic = false;
  bool _zoomThisSession = false;

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
    _activeRegion = region.evenAligned();
    _activeMic = recordMicrophone;
    _zoomThisSession = _options.autoZoom;

    final style = _options.cursorStyle;
    if (style != CursorStyle.off) {
      await _overlay.show(halo: style.drawsHalo, ripples: style.drawsRipples);
    }
    // Keep the face bubble above the recording chip and other windows.
    await CameraBubbleService.instance.bringToFront();
    // Start sampling just before FFmpeg so the log lines up with frame 0.
    _tracker.start(_activeRegion!);
    try {
      await super.start(region, recordMicrophone: recordMicrophone);
    } catch (_) {
      _tracker.stop();
      await _overlay.hide();
      _activeRegion = null;
      rethrow;
    }
  }

  @override
  Future<void> pause() async {
    await super.pause();
    _tracker.pause();
  }

  @override
  Future<void> resume() async {
    _tracker.resume();
    try {
      await super.resume();
    } catch (_) {
      _tracker.pause();
      rethrow;
    }
  }

  @override
  Future<String?> stop() async {
    final log = _tracker.stop();
    final region = _activeRegion;
    final hasAudio = _activeMic;
    final zoom = _zoomThisSession;
    _activeRegion = null;
    await _overlay.hide();

    final produced = await super.stop();
    if (produced == null || region == null) {
      return produced;
    }
    final duration = Duration(
      milliseconds: log.samples.isEmpty ? 0 : (log.samples.last.t * 1000).round(),
    );
    final focus = log.clicks.isEmpty ? null : log.clicks.first.t + 1.2;

    var result = produced;
    if (zoom) {
      AppLogger.info(
        'Cursor log: ${log.samples.length} samples, ${log.clicks.length} clicks',
      );
      try {
        final pan = _options.panTau;
        result = await applyAutoZoom(
          inputPath: produced,
          log: log,
          width: region.width,
          height: region.height,
          encoder: encoder,
          hasAudio: hasAudio,
          settings: AutoZoomSettings(
            maxZoom: _options.zoomLevel,
            hold: _options.holdSeconds,
            panTau: pan,
            zoomTau: pan + 0.04,
          ),
          runner: _zoomRunner,
        );
      } catch (error, stack) {
        AppLogger.error('Auto-zoom crashed; keeping original', error, stack);
        result = produced;
      }
    }

    RecordingLibrary.instance.register(
      LastRecording(
        finalPath: result,
        originalPath: result == produced ? null : produced,
        focusSeconds: focus,
        width: region.width,
        height: region.height,
        duration: duration,
        hasAudio: hasAudio,
      ),
    );
    return result;
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
