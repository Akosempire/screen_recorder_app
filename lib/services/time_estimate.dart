/// Rough "how long will this take" numbers, shown before slow work starts so
/// nobody is left wondering, and "time left" while it runs.
library;

/// The kinds of processing that redraw every frame of the video.
enum RedrawKind {
  /// Export with trims, cuts, a background or a quality change.
  export,

  /// Auto-zoom (each frame is moved and scaled, then encoded).
  autoZoom,
}

/// A likely range for redrawing [video] on an ordinary laptop. Real speed
/// depends on the computer, so the range is deliberately wide.
({Duration low, Duration high}) estimateRedraw(Duration video, RedrawKind kind, {int height = 1080}) {
  // Fraction of the video's own length, measured with FFmpeg's libx264 on a
  // mid-range laptop at 1080p (fast machine → low, older one → high).
  final (double low, double high) = switch (kind) {
    RedrawKind.export => (0.15, 0.5),
    RedrawKind.autoZoom => (0.4, 1.1),
  };
  // Fewer pixels, quicker; 4K takes about twice as long as 1080p.
  final scale = height <= 0
      ? 1.0
      : height <= 720
          ? 0.5
          : height > 1440
              ? 2.0
              : 1.0;
  Duration part(double f) => Duration(milliseconds: (video.inMilliseconds * f * scale).round());
  return (low: part(low), high: part(high));
}

/// "under a minute", "about 4 min", "about 1 h 20 min".
String approxDuration(Duration d) {
  if (d < const Duration(seconds: 50)) return 'under a minute';
  final minutes = (d.inSeconds / 60).round();
  if (minutes < 60) return 'about $minutes min';
  final h = minutes ~/ 60;
  final m = ((minutes % 60) / 5).round() * 5;
  if (m == 0 || m == 60) return 'about ${m == 60 ? h + 1 : h} h';
  return 'about $h h $m min';
}

/// "under a minute", "1–3 min", "40 min–2 h".
String approxRange(({Duration low, Duration high}) r) {
  if (r.high < const Duration(seconds: 50)) return 'under a minute';
  String part(Duration d) {
    final minutes = (d.inSeconds / 60).round().clamp(1, 1 << 30);
    if (minutes < 60) return '$minutes min';
    final h = minutes / 60;
    return h == h.roundToDouble() ? '${h.round()} h' : '${h.toStringAsFixed(1)} h';
  }

  final low = part(r.low), high = part(r.high);
  if (low == high) return 'about $low';
  // "1 min–3 min" → "1–3 min".
  if (low.endsWith(' min') && high.endsWith(' min')) return '${low.replaceAll(' min', '')}–$high';
  if (low.endsWith(' h') && high.endsWith(' h')) return '${low.replaceAll(' h', '')}–$high';
  return '$low–$high';
}

/// Time left from how long the work has taken so far, once it can be told
/// (after 3% and a couple of seconds); null before that.
Duration? timeLeft(Duration elapsed, double fraction) {
  final f = fraction.clamp(0.0, 1.0);
  if (f < 0.03 || elapsed.inMilliseconds < 2000) return null;
  if (f >= 1) return Duration.zero;
  return Duration(milliseconds: (elapsed.inMilliseconds * (1 - f) / f).round());
}

/// "42% · about 3 min left", or "42%" while time left is unknown.
String progressLabel(double fraction, Duration? left) {
  final pct = '${(fraction.clamp(0.0, 1.0) * 100).round()}%';
  if (left == null) return pct;
  return '$pct · ${approxDuration(left)} left';
}

/// Tracks a running job and gives its time left.
class ProgressClock {
  ProgressClock({DateTime? started}) : started = started ?? DateTime.now();
  final DateTime started;
  double fraction = 0;
  Duration? left;

  void update(double f, {DateTime? now}) {
    fraction = f.clamp(0.0, 1.0);
    left = timeLeft((now ?? DateTime.now()).difference(started), fraction);
  }

  String get label => progressLabel(fraction, left);
}
