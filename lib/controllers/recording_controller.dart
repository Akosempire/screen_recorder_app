import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/display_server.dart';
import '../models/recorder_exception.dart';
import '../models/recording_state.dart';
import '../models/screen_region.dart';
import '../services/app_logger.dart';
import '../services/file_save_service.dart';
import '../services/last_save_path_store.dart';
import '../services/screen_recorder.dart';

class RecordingController extends ChangeNotifier {
  RecordingController({
    required ScreenRecorder recorder,
    required FileSaveService fileSaveService,
    RecordingStorage storage = const IoRecordingStorage(),
    LastSavePathStore? lastSavePathStore,
    DesktopGeometry? geometry,
  })  : _recorder = recorder,
        _fileSaveService = fileSaveService,
        _storage = storage,
        _lastSavePathStore = lastSavePathStore ?? MemoryLastSavePathStore(),
        _geometry = geometry;

  final ScreenRecorder _recorder;
  final FileSaveService _fileSaveService;
  final RecordingStorage _storage;
  final LastSavePathStore _lastSavePathStore;

  DesktopGeometry? _geometry;
  RecordingState _state = RecordingState.idle;
  bool _captureAvailable = true;
  ScreenRegion? _region;
  String? _errorMessage;
  String? _statusDetail;
  String? _outputPath;
  String? _unsavedPath;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  DateTime? _segmentStartedAt;
  Duration _accumulated = Duration.zero;

  RecordingState get state => _state;
  ScreenRegion? get region => _region;
  String? get errorMessage => _errorMessage;
  String? get statusDetail => _statusDetail;
  String? get outputPath => _outputPath;
  String? get unsavedPath => _unsavedPath;
  Duration get elapsed => _elapsed;
  DesktopGeometry? get geometry => _geometry;
  String get backendName => _recorder.backendName;
  bool get captureAvailable => _captureAvailable;

  bool get canBeginSelection =>
      _captureAvailable && _state.canBeginSelection;
  bool get canPause => _state.canPause;
  bool get canResume => _state.canResume;
  bool get canStop => _state.canStop;
  bool get canStartRecording => _state.canStartRecording && _region != null;

  void updateGeometry(DesktopGeometry geometry) {
    _geometry = geometry;
    notifyListeners();
  }

  /// Used when FFmpeg or the capture backend is missing at startup.
  void markStartupError(String message) {
    _captureAvailable = false;
    _errorMessage = message;
    _statusDetail = message;
    _state = RecordingState.error;
    notifyListeners();
  }

  void beginSelection() {
    _assertCan('select a region', _state.canBeginSelection);
    _errorMessage = null;
    _statusDetail = null;
    _outputPath = null;
    _unsavedPath = null;
    _region = null;
    _elapsed = Duration.zero;
    _accumulated = Duration.zero;
    _setState(RecordingState.selectingRegion);
  }

  void cancelSelection() {
    if (!_state.canCancelSelection) {
      return;
    }
    _region = null;
    _setState(RecordingState.idle);
  }

  void updateReadyRegion(ScreenRegion region) {
    if (!_state.canConfirmRegion) {
      return;
    }
    _region = region.evenAligned();
    if (_geometry != null) {
      _region = _region!.clampedTo(_geometry!.bounds);
    }
    if (_region!.isValid) {
      if (_state != RecordingState.ready) {
        _setState(RecordingState.ready);
      } else {
        notifyListeners();
      }
    } else if (_state == RecordingState.ready) {
      _setState(RecordingState.selectingRegion);
    }
  }

  Future<void> startRecording() async {
    _assertCan('start recording', _state.canStartRecording);
    final region = _region;
    if (region == null || !region.isValid) {
      throw const RecorderException(
        userMessage: 'Select a recording region of at least 100×100 pixels.',
      );
    }
    _errorMessage = null;
    _unsavedPath = null;
    _outputPath = null;
    _elapsed = Duration.zero;
    _accumulated = Duration.zero;
    try {
      await _recorder.start(region);
      _segmentStartedAt = DateTime.now();
      _startTicker();
      _setState(RecordingState.recording);
    } on RecorderException catch (error, stack) {
      AppLogger.error(error.userMessage, error, stack);
      _fail(error.userMessage);
      rethrow;
    } catch (error, stack) {
      AppLogger.error('Failed to start recording', error, stack);
      _fail('Could not start recording.');
      throw RecorderException(
        userMessage: 'Could not start recording.',
        technicalDetails: error.toString(),
      );
    }
  }

  Future<void> pause() async {
    _assertCan('pause', _state.canPause);
    try {
      await _recorder.pause();
      _accumulateElapsed();
      _segmentStartedAt = null;
      _setState(RecordingState.paused);
    } on RecorderException catch (error, stack) {
      AppLogger.error(error.userMessage, error, stack);
      _fail(error.userMessage);
      rethrow;
    } catch (error, stack) {
      AppLogger.error('Pause failed', error, stack);
      _fail('Could not pause recording.');
    }
  }

  Future<void> resume() async {
    _assertCan('resume', _state.canResume);
    try {
      await _recorder.resume();
      _segmentStartedAt = DateTime.now();
      _startTicker();
      _setState(RecordingState.recording);
    } on RecorderException catch (error, stack) {
      AppLogger.error(error.userMessage, error, stack);
      _fail(error.userMessage);
      rethrow;
    } catch (error, stack) {
      AppLogger.error('Resume failed', error, stack);
      _fail('Could not resume recording.');
    }
  }

  Future<void> togglePause() async {
    if (_state.canPause) {
      await pause();
    } else if (_state.canResume) {
      await resume();
    }
  }

  /// Stops capture, opens a save dialog, and copies the file if the user confirms.
  /// Cancelling the dialog keeps the temp recording.
  Future<void> stopAndSave() async {
    _assertCan('stop', _state.canStop);
    _setState(RecordingState.stopping);
    _accumulateElapsed();
    _stopTicker();
    String? produced;
    try {
      produced = await _recorder.stop();
    } on RecorderException catch (error, stack) {
      AppLogger.error(error.userMessage, error, stack);
      _fail(error.userMessage);
      return;
    } catch (error, stack) {
      AppLogger.error('Stop failed', error, stack);
      _fail('Could not stop recording cleanly.');
      return;
    }

    if (produced == null) {
      _fail('No video was produced.');
      return;
    }

    final exists = await _storage.exists(produced);
    if (!exists) {
      _fail('The recording file could not be created.');
      AppLogger.error('Missing output file $produced');
      return;
    }

    _setState(RecordingState.saving);
    final suggested = _suggestedName();
    final lastDirectory = await _lastSavePathStore.lastDirectory();
    String? destination;
    try {
      destination = await _fileSaveService.chooseSaveLocation(
        suggestedName: suggested,
        initialDirectory: lastDirectory,
      );
    } catch (error, stack) {
      AppLogger.error('Save dialog failed', error, stack);
      _unsavedPath = produced;
      _statusDetail =
          'The save dialog failed. The recording is still at $produced';
      _outputPath = produced;
      _setState(RecordingState.completed);
      return;
    }

    if (destination == null || destination.isEmpty) {
      _unsavedPath = produced;
      _outputPath = produced;
      _statusDetail =
          'Save cancelled. The recording was kept at $produced';
      AppLogger.info('Save cancelled; kept $produced');
      _setState(RecordingState.completed);
      return;
    }

    destination = _ensureVideoExtension(destination);
    try {
      await _storage.persist(produced, destination);
      await _lastSavePathStore.remember(destination);
      _outputPath = destination;
      _unsavedPath = null;
      _statusDetail = 'Saved to $destination';
      _setState(RecordingState.completed);
    } catch (error, stack) {
      AppLogger.error('Failed to save recording', error, stack);
      _unsavedPath = produced;
      _fail(
        'Could not write the file. The recording is still at $produced',
      );
    }
  }

  String _suggestedName() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'recording_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.mp4';
  }

  String _ensureVideoExtension(String path) {
    final ext = p.extension(path).toLowerCase();
    if (ext == '.mp4' || ext == '.mkv' || ext == '.webm') {
      return path;
    }
    return '$path.mp4';
  }

  void clearError() {
    if (_state == RecordingState.error) {
      _errorMessage = null;
      _setState(RecordingState.idle);
    }
  }

  /// After a failed start, return to idle so Start Recording works again.
  void recoverAfterFailure() {
    _stopTicker();
    if (_state == RecordingState.error ||
        _state == RecordingState.ready ||
        _state == RecordingState.selectingRegion) {
      _state = RecordingState.idle;
      notifyListeners();
    }
  }

  void _assertCan(String operation, bool allowed) {
    if (!allowed) {
      throw InvalidStateException(operation, _state.label.toLowerCase());
    }
  }

  void _fail(String message) {
    _stopTicker();
    _errorMessage = message;
    _setState(RecordingState.error);
  }

  void _setState(RecordingState next) {
    _state = next;
    notifyListeners();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _elapsed = _currentElapsed();
      notifyListeners();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _accumulateElapsed() {
    _elapsed = _currentElapsed();
    _accumulated = _elapsed;
    _segmentStartedAt = null;
  }

  Duration _currentElapsed() {
    final started = _segmentStartedAt;
    if (started == null) {
      return _accumulated;
    }
    return _accumulated + DateTime.now().difference(started);
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }
}
