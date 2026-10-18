import 'dart:async';

import 'package:flutter/foundation.dart';

/// What the app is doing between "Stop" and the Editor opening.
///
/// The small floating recording bar shows this as a quiet progress pill
/// (percentage and time left) so the user can keep working; the dashboard
/// only comes up when they click "Open" once the video is ready.
class ProcessingStatus extends ChangeNotifier {
  ProcessingStatus._();

  static final ProcessingStatus instance = ProcessingStatus._();

  String? _message;
  double? _progress;
  DateTime? _stepStarted;
  Duration? _remaining;
  Completer<void>? _open;

  /// Null when idle; otherwise a short label like "Auto-zoom".
  String? get message => _message;

  /// True from Stop until the Editor is opened.
  bool get active => _message != null;

  /// 0–1 for the current step, or null while it can't be measured.
  double? get progress => _progress;

  /// Estimated time left for the current step, once enough is known.
  Duration? get remaining => _remaining;

  /// The video is finished and waiting for the user to open it.
  bool get ready => _open != null && !_open!.isCompleted;

  /// Starts a step; progress is unknown until [report] is called.
  void begin(String message) {
    _message = message;
    _progress = null;
    _remaining = null;
    _stepStarted = DateTime.now();
    notifyListeners();
  }

  /// Progress of the current step (0–1). Time left is estimated from how
  /// long the step has taken so far.
  void report(double fraction, {DateTime? now}) {
    if (!active) return;
    final f = fraction.clamp(0.0, 1.0).toDouble();
    final at = now ?? DateTime.now();
    final elapsed = at.difference(_stepStarted ?? at);
    _progress = f;
    _remaining = (f >= 0.03 && elapsed.inMilliseconds > 1500)
        ? Duration(milliseconds: (elapsed.inMilliseconds * (1 - f) / f).round())
        : null;
    notifyListeners();
  }

  /// Marks the video as ready and waits until [open] is called (the user
  /// clicked "Open"), so the dashboard never jumps in front of their work.
  Future<void> waitForOpen() {
    _message = 'Video ready';
    _progress = 1;
    _remaining = null;
    final open = _open = Completer<void>();
    notifyListeners();
    return open.future;
  }

  /// The user asked to see the finished video.
  void open() {
    final open = _open;
    if (open != null && !open.isCompleted) open.complete();
  }

  void end() {
    open();
    if (_message == null && _open == null) return;
    _message = null;
    _progress = null;
    _remaining = null;
    _stepStarted = null;
    _open = null;
    notifyListeners();
  }
}

/// Reads FFmpeg `-progress` output lines (`out_time_us=…`) and reports the
/// fraction of [total] done.
void Function(String line) ffmpegProgressReader(
  Duration total,
  void Function(double fraction) onFraction,
) {
  final totalUs = total.inMicroseconds;
  return (line) {
    if (totalUs <= 0) return;
    final eq = line.indexOf('=');
    if (eq < 0) return;
    final key = line.substring(0, eq).trim();
    // out_time_ms is (despite its name) also microseconds.
    if (key != 'out_time_us' && key != 'out_time_ms') return;
    final us = int.tryParse(line.substring(eq + 1).trim());
    if (us == null || us < 0) return;
    onFraction(us / totalUs);
  };
}
