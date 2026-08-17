import '../models/screen_region.dart';

/// Capture backend abstraction. Implementations must capture video only.
abstract class ScreenRecorder {
  Future<void> start(ScreenRegion region);

  Future<void> pause();

  Future<void> resume();

  /// Stops capture and returns a path to the produced video, or null if
  /// nothing was recorded.
  Future<String?> stop();

  String get backendName;

  bool get isRecording;
}

/// Thrown / used when the current Linux session cannot be recorded.
class UnsupportedRecorder implements ScreenRecorder {
  UnsupportedRecorder(this.reason);

  final String reason;

  @override
  String get backendName => 'unsupported';

  @override
  bool get isRecording => false;

  Never _fail() {
    throw RecorderUnavailable(reason);
  }

  @override
  Future<void> start(ScreenRegion region) async => _fail();

  @override
  Future<void> pause() async => _fail();

  @override
  Future<void> resume() async => _fail();

  @override
  Future<String?> stop() async => _fail();
}

class RecorderUnavailable implements Exception {
  RecorderUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}
