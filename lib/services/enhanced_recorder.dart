import '../models/screen_region.dart';
import 'app_logger.dart';
import 'auto_zoom.dart';
import 'camera_bubble.dart';
import 'cursor_overlay.dart';
import 'cursor_tracker.dart';
import 'ffmpeg_process_manager.dart';
import 'ffmpeg_recorder.dart';
import 'processing_status.dart';
import 'recording_library.dart';
import 'recording_options.dart';

/// Segmenting FFmpeg recorder plus everything that happens around capture,
/// shared by Windows, Linux (X11) and macOS:
/// cursor tracking for auto-zoom, the live cursor overlay where supported,
/// the progress pill after Stop, and handing the result to the library.
class EnhancedScreenRecorder extends SegmentingScreenRecorder {
  EnhancedScreenRecorder({
    required super.backendName,
    required super.commandBuilder,
    required super.encoder,
    super.stopStyle = StopStyle.ffmpegQuit,
    super.processManager,
    ProcessRunner runner = const ProcessRunner(),
    CursorTracker? tracker,
    CursorOverlay? overlay,
    RecordingOptions? options,
  })  : zoomRunner = runner,
        tracker = tracker ?? CursorTracker(),
        overlay = overlay ?? CursorOverlay(),
        options = options ?? RecordingOptions.instance,
        super(runner: runner);

  final ProcessRunner zoomRunner;
  final CursorTracker tracker;
  final CursorOverlay overlay;
  final RecordingOptions options;

  ScreenRegion? _activeRegion;
  bool _activeMic = false;
  bool _zoomThisSession = false;

  /// Auto-zoom needs the mouse position (not available on Wayland).
  bool get canAutoZoom => tracker.isAvailable;

  @override
  Future<void> start(
    ScreenRegion region, {
    bool recordMicrophone = false,
  }) async {
    _activeRegion = region.evenAligned();
    _activeMic = recordMicrophone;
    _zoomThisSession = options.autoZoom && canAutoZoom;

    final style = options.cursorStyle;
    if (style != CursorStyle.off) {
      await overlay.show(halo: style.drawsHalo, ripples: style.drawsRipples);
    }
    // Keep the face bubble above the recording chip and other windows.
    await CameraBubbleService.instance.bringToFront();
    // Start sampling just before FFmpeg so the log lines up with frame 0.
    tracker.start(_activeRegion!);
    try {
      await super.start(region, recordMicrophone: recordMicrophone);
    } catch (_) {
      tracker.stop();
      await overlay.hide();
      _activeRegion = null;
      rethrow;
    }
  }

  @override
  Future<void> pause() async {
    await super.pause();
    tracker.pause();
  }

  @override
  Future<void> resume() async {
    tracker.resume();
    try {
      await super.resume();
    } catch (_) {
      tracker.pause();
      rethrow;
    }
  }

  @override
  Future<String?> stop() async {
    final log = tracker.stop();
    final region = _activeRegion;
    final hasAudio = _activeMic;
    final zoom = _zoomThisSession;
    _activeRegion = null;
    await overlay.hide();

    // The floating bar turns into a progress pill from here until the user
    // opens the finished video; nothing else pops up over their work.
    ProcessingStatus.instance.begin('Saving');
    final String? produced;
    try {
      produced = await super.stop();
    } catch (_) {
      ProcessingStatus.instance.end();
      rethrow;
    }
    if (produced == null || region == null) {
      ProcessingStatus.instance.end();
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
      ProcessingStatus.instance.begin('Auto-zoom');
      try {
        final pan = options.panTau;
        result = await applyAutoZoom(
          inputPath: produced,
          log: log,
          width: region.width,
          height: region.height,
          encoder: encoder,
          hasAudio: hasAudio,
          settings: AutoZoomSettings(
            maxZoom: options.zoomLevel,
            hold: options.holdSeconds,
            panTau: pan,
            zoomTau: pan + 0.04,
          ),
          runner: zoomRunner,
          duration: duration,
          onProgress: ProcessingStatus.instance.report,
        );
      } catch (error, stack) {
        AppLogger.error('Auto-zoom crashed; keeping original', error, stack);
        result = produced;
      }
    }

    ProcessingStatus.instance.begin('Preparing');
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
