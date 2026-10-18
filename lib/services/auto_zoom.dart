import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'cursor_tracker.dart';
import 'ffmpeg_binary.dart';
import 'ffmpeg_process_manager.dart';

/// Camera keyframe: the visible source rectangle at video frame [frame].
class ZoomKeyframe {
  final double frame;
  final double left;
  final double top;
  final double right;
  final double bottom;

  const ZoomKeyframe(this.frame, this.left, this.top, this.right, this.bottom);

  List<double> get values => [left, top, right, bottom];

  @override
  String toString() =>
      'ZoomKeyframe(f=$frame, ${left.toStringAsFixed(1)},${top.toStringAsFixed(1)}'
      ' → ${right.toStringAsFixed(1)},${bottom.toStringAsFixed(1)})';
}

/// Settings for the automatic zoom-and-follow camera.
class AutoZoomSettings {
  /// Zoom factor while focused on a click (2.0 = twice as close).
  final double maxZoom;

  /// Seconds before a click that the camera starts moving in.
  final double leadIn;

  /// Seconds the camera stays zoomed after the last click in a burst.
  final double hold;

  /// Clicks closer together than this stay in one zoomed shot.
  final double mergeGap;

  /// Smoothing time constants (seconds). Larger = slower, softer motion.
  final double zoomTau;
  final double panTau;

  final int fps;

  /// Emit a keyframe every N frames before simplification.
  final int keyframeStep;

  const AutoZoomSettings({
    this.maxZoom = 1.8,
    this.leadIn = 0.45,
    this.hold = 2.6,
    this.mergeGap = 1.2,
    this.zoomTau = 0.32,
    this.panTau = 0.28,
    this.fps = 30,
    this.keyframeStep = 3,
  });
}

class _Interval {
  double start;
  double end;
  _Interval(this.start, this.end);
}

/// Pure camera planner: turns a cursor log into smooth zoom/pan keyframes.
///
/// Returns an empty list when there is nothing to zoom on (no clicks).
List<ZoomKeyframe> planAutoZoom({
  required CursorLog log,
  required int width,
  required int height,
  AutoZoomSettings settings = const AutoZoomSettings(),
  double? duration,
}) {
  if (log.clicks.isEmpty || width <= 0 || height <= 0) {
    return const [];
  }
  final end = duration ??
      math.max(
        log.samples.isEmpty ? 0.0 : log.samples.last.t,
        log.clicks.last.t + settings.hold,
      );
  if (end <= 0) return const [];

  // 1. Focus intervals around click bursts.
  final clicks = [...log.clicks]..sort((a, b) => a.t.compareTo(b.t));
  final intervals = <_Interval>[];
  for (final click in clicks) {
    final start = math.max(0.0, click.t - settings.leadIn);
    final stop = click.t + settings.hold;
    if (intervals.isNotEmpty &&
        start - intervals.last.end <= settings.mergeGap) {
      intervals.last.end = math.max(intervals.last.end, stop);
    } else {
      intervals.add(_Interval(start, stop));
    }
  }

  // 2. Simulate a damped camera at the video frame rate.
  final fps = settings.fps;
  final dt = 1.0 / fps;
  final frames = (end * fps).ceil() + 1;
  final zoomAlpha = 1 - math.exp(-dt / settings.zoomTau);
  final panAlpha = 1 - math.exp(-dt / settings.panTau);
  final w = width.toDouble();
  final h = height.toDouble();

  var z = 1.0;
  var cx = w / 2;
  var cy = h / 2;
  var sampleIndex = 0;
  var intervalIndex = 0;
  final raw = <ZoomKeyframe>[];

  for (var f = 0; f < frames; f++) {
    final t = f * dt;
    while (intervalIndex < intervals.length &&
        intervals[intervalIndex].end < t) {
      intervalIndex++;
    }
    final focused = intervalIndex < intervals.length &&
        intervals[intervalIndex].start <= t;

    // Cursor position at t (linear interpolation across samples).
    while (sampleIndex + 1 < log.samples.length &&
        log.samples[sampleIndex + 1].t <= t) {
      sampleIndex++;
    }
    double px;
    double py;
    if (log.samples.isEmpty) {
      px = w / 2;
      py = h / 2;
    } else if (sampleIndex + 1 < log.samples.length &&
        log.samples[sampleIndex].t <= t) {
      final a = log.samples[sampleIndex];
      final b = log.samples[sampleIndex + 1];
      final span = b.t - a.t;
      final k = span <= 0 ? 0.0 : ((t - a.t) / span).clamp(0.0, 1.0);
      px = a.x + (b.x - a.x) * k;
      py = a.y + (b.y - a.y) * k;
    } else {
      final s = log.samples[sampleIndex];
      px = s.x;
      py = s.y;
    }
    px = px.clamp(0.0, w);
    py = py.clamp(0.0, h);

    final targetZ = focused ? settings.maxZoom : 1.0;
    final targetX = focused ? px : w / 2;
    final targetY = focused ? py : h / 2;

    if (f == 0) {
      z = targetZ;
      cx = targetX;
      cy = targetY;
    } else {
      z += (targetZ - z) * zoomAlpha;
      cx += (targetX - cx) * panAlpha;
      cy += (targetY - cy) * panAlpha;
    }

    // Keep the view inside the frame.
    final halfW = w / (2 * z);
    final halfH = h / (2 * z);
    final vx = cx.clamp(halfW, w - halfW);
    final vy = cy.clamp(halfH, h - halfH);

    if (f % settings.keyframeStep == 0 || f == frames - 1) {
      raw.add(ZoomKeyframe(
        f.toDouble(),
        vx - halfW,
        vy - halfH,
        vx + halfW,
        vy + halfH,
      ));
    }
  }

  return simplifyKeyframes(raw);
}

/// Drops keyframes that linear interpolation already reproduces within
/// [epsilon] pixels, so long idle stretches collapse to two points.
List<ZoomKeyframe> simplifyKeyframes(
  List<ZoomKeyframe> keys, {
  double epsilon = 0.35,
}) {
  if (keys.length <= 2) return List.unmodifiable(keys);
  final kept = <ZoomKeyframe>[keys.first];
  for (var i = 1; i < keys.length - 1; i++) {
    final prev = kept.last;
    final next = keys[i + 1];
    final cur = keys[i];
    final span = next.frame - prev.frame;
    final k = span <= 0 ? 0.0 : (cur.frame - prev.frame) / span;
    final pv = prev.values;
    final nv = next.values;
    final cv = cur.values;
    var needed = false;
    for (var j = 0; j < 4; j++) {
      final predicted = pv[j] + (nv[j] - pv[j]) * k;
      if ((predicted - cv[j]).abs() > epsilon) {
        needed = true;
        break;
      }
    }
    if (needed) kept.add(cur);
  }
  kept.add(keys.last);
  return List.unmodifiable(kept);
}

String _num(double v) {
  final s = v.toStringAsFixed(2);
  return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
}

/// Builds a piecewise-linear FFmpeg expression of the frame index `in`.
///
/// Segments are arranged as a balanced `if(lt(...))` tree so each frame
/// evaluates O(log n) nodes even for long recordings.
String piecewiseExpression(
  List<ZoomKeyframe> keys,
  double Function(ZoomKeyframe) value,
) {
  if (keys.isEmpty) return '0';
  if (keys.length == 1) return _num(value(keys.first));

  String segment(int i) {
    final a = keys[i];
    final b = keys[i + 1];
    final va = value(a);
    final vb = value(b);
    if ((vb - va).abs() < 0.005) return _num(va);
    final slope = (vb - va) / (b.frame - a.frame);
    return '(${_num(va)}+${slope.toStringAsFixed(5)}*(in-${_num(a.frame)}))';
  }

  // Segments [lo, hi) — segment i spans keys[i]..keys[i+1].
  String tree(int lo, int hi) {
    if (hi - lo == 1) return segment(lo);
    final mid = (lo + hi) >> 1;
    return 'if(lt(in,${_num(keys[mid].frame)}),${tree(lo, mid)},${tree(mid, hi)})';
  }

  final first = keys.first;
  final last = keys.last;
  return 'if(lt(in,${_num(first.frame)}),${_num(value(first))},'
      'if(gte(in,${_num(last.frame)}),${_num(value(last))},'
      '${tree(0, keys.length - 1)}))';
}

/// Full filtergraph text (written to a script file to avoid command-line
/// length limits on Windows).
String buildAutoZoomFilter(
  List<ZoomKeyframe> keys, {
  required int width,
  required int height,
  int fps = 30,
}) {
  final l = piecewiseExpression(keys, (k) => k.left);
  final t = piecewiseExpression(keys, (k) => k.top);
  final r = piecewiseExpression(keys, (k) => k.right);
  final b = piecewiseExpression(keys, (k) => k.bottom);
  final ranges = zoomedFrameRanges(keys, width: width, height: height);
  // Frames outside every zoomed range pass through untouched (much faster).
  final enable = ranges.isEmpty
      ? ''
      : ":enable='${ranges.map((range) => 'between(n,${_num(range.$1)},${_num(range.$2)})').join('+')}'";
  return 'fps=$fps,'
      "perspective=x0='$l':y0='$t':x1='$r':y1='$t':"
      "x2='$l':y2='$b':x3='$r':y3='$b':"
      'interpolation=cubic:sense=source:eval=frame$enable,'
      'format=yuv420p';
}

/// Frame ranges where the camera is not showing the full frame.
List<(double, double)> zoomedFrameRanges(
  List<ZoomKeyframe> keys, {
  required int width,
  required int height,
}) {
  bool isFull(ZoomKeyframe k) =>
      k.left.abs() < 0.5 &&
      k.top.abs() < 0.5 &&
      (k.right - width).abs() < 0.5 &&
      (k.bottom - height).abs() < 0.5;
  final ranges = <(double, double)>[];
  for (var i = 0; i + 1 < keys.length; i++) {
    final a = keys[i];
    final b = keys[i + 1];
    if (isFull(a) && isFull(b)) continue;
    if (ranges.isNotEmpty && ranges.last.$2 >= a.frame) {
      ranges[ranges.length - 1] = (ranges.last.$1, b.frame);
    } else {
      ranges.add((a.frame, b.frame));
    }
  }
  return ranges;
}

/// Applies the auto-zoom camera to [inputPath]. Returns the new file, or the
/// original path when there was nothing to zoom or FFmpeg failed.
Future<String> applyAutoZoom({
  required String inputPath,
  required CursorLog log,
  required int width,
  required int height,
  required String encoder,
  bool hasAudio = false,
  AutoZoomSettings settings = const AutoZoomSettings(),
  ProcessRunner runner = const ProcessRunner(),
}) async {
  final keys = planAutoZoom(
    log: log,
    width: width,
    height: height,
    settings: settings,
  );
  if (keys.length < 2) {
    AppLogger.info('Auto-zoom: no clicks recorded; keeping original video');
    return inputPath;
  }

  final dir = p.dirname(inputPath);
  final script = File(p.join(dir, 'autozoom_filter.txt'));
  await script.writeAsString(
    buildAutoZoomFilter(
      keys,
      width: width,
      height: height,
      fps: settings.fps,
    ),
  );
  final output = p.join(dir, 'autozoom.mp4');

  AppLogger.info('Auto-zoom: ${keys.length} keyframes → $output');
  final result = await runner.run(ffmpegExecutable, [
    '-y',
    '-i',
    inputPath,
    '-filter_script:v',
    script.path,
    '-c:v',
    encoder,
    if (encoder != 'mpeg4') ...['-preset', 'veryfast', '-crf', '20'],
    '-pix_fmt',
    'yuv420p',
    if (hasAudio) ...['-c:a', 'copy'] else '-an',
    '-movflags',
    '+faststart',
    output,
  ]);
  if (result.exitCode != 0 || !await File(output).exists()) {
    AppLogger.warn('Auto-zoom failed; keeping original. ${result.stderr}');
    return inputPath;
  }
  return output;
}
