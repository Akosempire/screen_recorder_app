import 'package:flutter/foundation.dart';

/// What the app is doing between "Stop" and the Editor opening, so the
/// dashboard can show it instead of leaving the small recording bar on screen
/// while the video is finished (auto-zoom can take about as long as the
/// recording itself).
class ProcessingStatus extends ChangeNotifier {
  ProcessingStatus._();

  static final ProcessingStatus instance = ProcessingStatus._();

  String? _message;
  DateTime? _since;

  /// Null when idle; otherwise a short line like "Adding auto-zoom…".
  String? get message => _message;

  /// True once screen capture has stopped and the file is being finished.
  bool get active => _message != null;

  /// When the current step started (for an elapsed-time readout).
  DateTime? get since => _since;

  void begin(String message) {
    _message = message;
    _since ??= DateTime.now();
    notifyListeners();
  }

  void end() {
    if (_message == null && _since == null) return;
    _message = null;
    _since = null;
    notifyListeners();
  }
}
