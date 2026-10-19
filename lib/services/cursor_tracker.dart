import 'dart:async';

import '../models/screen_region.dart';
import '../platform/cursor_input.dart';

/// One cursor sample on the video timeline (seconds since recording start,
/// excluding paused time). Coordinates are relative to the capture region.
class CursorSample {
  final double t;
  final double x;
  final double y;

  const CursorSample(this.t, this.x, this.y);
}

/// A mouse-button press on the video timeline.
class CursorClick {
  final double t;
  final double x;
  final double y;
  final bool right;

  const CursorClick(this.t, this.x, this.y, {this.right = false});
}

class CursorLog {
  final List<CursorSample> samples;
  final List<CursorClick> clicks;

  const CursorLog(this.samples, this.clicks);

  bool get isEmpty => samples.isEmpty;
}

/// Polls the system cursor while recording so auto-zoom can follow it.
///
/// Time only advances while [resume]d, so the log lines up with the merged
/// video after pauses are cut out.
class CursorTracker {
  CursorTracker({
    CursorInput? input,
    this.interval = const Duration(milliseconds: 33),
  }) : _input = input ?? platformCursorInput();

  final CursorInput? _input;
  final Duration interval;

  final List<CursorSample> _samples = [];
  final List<CursorClick> _clicks = [];
  ScreenRegion? _region;
  Timer? _timer;
  final Stopwatch _clock = Stopwatch();
  bool _leftWasDown = false;
  bool _rightWasDown = false;

  bool get isAvailable => _input != null;

  void start(ScreenRegion region) {
    _samples.clear();
    _clicks.clear();
    _region = region;
    _clock
      ..reset()
      ..start();
    _leftWasDown = false;
    _rightWasDown = false;
    _startTimer();
  }

  void pause() {
    _clock.stop();
    _timer?.cancel();
    _timer = null;
  }

  void resume() {
    if (_region == null) return;
    _clock.start();
    _startTimer();
  }

  CursorLog stop() {
    pause();
    final log = CursorLog(
      List.unmodifiable(_samples),
      List.unmodifiable(_clicks),
    );
    _region = null;
    return log;
  }

  void _startTimer() {
    _timer?.cancel();
    if (_input == null) return;
    _sample();
    _timer = Timer.periodic(interval, (_) => _sample());
  }

  void _sample() {
    final input = _input;
    final region = _region;
    if (input == null || region == null) return;
    final CursorState state;
    try {
      state = input.cursor();
    } catch (_) {
      return;
    }
    final t = _clock.elapsedMicroseconds / 1e6;
    final x = (state.x - region.x).toDouble();
    final y = (state.y - region.y).toDouble();
    _samples.add(CursorSample(t, x, y));

    final inside =
        x >= 0 && y >= 0 && x < region.width && y < region.height;
    if (state.leftDown && !_leftWasDown && inside) {
      _clicks.add(CursorClick(t, x, y));
    }
    if (state.rightDown && !_rightWasDown && inside) {
      _clicks.add(CursorClick(t, x, y, right: true));
    }
    _leftWasDown = state.leftDown;
    _rightWasDown = state.rightDown;
  }
}
