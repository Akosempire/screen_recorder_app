import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder_app/services/auto_zoom.dart';
import 'package:screen_recorder_app/services/cursor_tracker.dart';
import 'package:screen_recorder_app/services/ffmpeg_binary.dart';

CursorLog _circleLog({
  required int width,
  required int height,
  required double seconds,
  required List<double> clickTimes,
}) {
  final samples = <CursorSample>[];
  for (var i = 0; i <= seconds * 30; i++) {
    final t = i / 30;
    samples.add(CursorSample(
      t,
      width / 2 + width * 0.35 * math.cos(t * 0.6),
      height / 2 + height * 0.35 * math.sin(t * 0.6),
    ));
  }
  CursorSample at(double t) =>
      samples.reduce((a, b) => (a.t - t).abs() <= (b.t - t).abs() ? a : b);
  final clicks = [
    for (final t in clickTimes) CursorClick(at(t).t, at(t).x, at(t).y),
  ];
  return CursorLog(samples, clicks);
}

void main() {
  test('no clicks means no zoom', () {
    final log = _circleLog(width: 1280, height: 720, seconds: 5, clickTimes: []);
    expect(planAutoZoom(log: log, width: 1280, height: 720), isEmpty);
  });

  test('camera starts full frame, zooms in around clicks, and returns', () {
    final log = _circleLog(
      width: 1280,
      height: 720,
      seconds: 14,
      clickTimes: [2, 2.8, 9],
    );
    final keys = planAutoZoom(log: log, width: 1280, height: 720);
    expect(keys.length, greaterThan(4));

    final first = keys.first;
    expect(first.left, closeTo(0, 0.5));
    expect(first.right, closeTo(1280, 0.5));

    // Every keyframe stays inside the frame and keeps the aspect ratio.
    for (final k in keys) {
      expect(k.left, greaterThanOrEqualTo(-0.01));
      expect(k.top, greaterThanOrEqualTo(-0.01));
      expect(k.right, lessThanOrEqualTo(1280.01));
      expect(k.bottom, lessThanOrEqualTo(720.01));
      final aspect = (k.right - k.left) / (k.bottom - k.top);
      expect(aspect, closeTo(1280 / 720, 0.01));
    }

    // Shortly after the first click the view is noticeably zoomed in.
    final atClick = keys.lastWhere((k) => k.frame <= 2.5 * 30);
    expect(atClick.right - atClick.left, lessThan(1280 * 0.75));

    // By the end it has zoomed back out to the full frame.
    final last = keys.last;
    expect(last.right - last.left, closeTo(1280, 2));
  });

  test('simplification collapses idle stretches', () {
    final keys = [
      for (var f = 0; f <= 300; f += 3)
        ZoomKeyframe(f.toDouble(), 0, 0, 1280, 720),
    ];
    expect(simplifyKeyframes(keys).length, 2);
  });

  test('expression is a balanced tree and clamps the ends', () {
    final keys = [
      const ZoomKeyframe(0, 0, 0, 1280, 720),
      const ZoomKeyframe(30, 100, 50, 900, 500),
      const ZoomKeyframe(60, 200, 100, 1000, 550),
      const ZoomKeyframe(90, 0, 0, 1280, 720),
    ];
    final expr = piecewiseExpression(keys, (k) => k.left);
    expect(expr, startsWith('if(lt(in,0),0,if(gte(in,90),0,'));
    expect(expr, contains('if(lt(in,30)'));
    final filter = buildAutoZoomFilter(keys, width: 1280, height: 720);
    expect(filter, contains('perspective='));
    expect(filter, contains("enable='between(n,0,90)'"));
  });

  test('renders through FFmpeg', () async {
    final ffmpeg = ffmpegExecutable;
    try {
      final probe = await Process.run(ffmpeg, ['-version']);
      if (probe.exitCode != 0) {
        markTestSkipped('ffmpeg not available');
        return;
      }
    } on ProcessException {
      markTestSkipped('ffmpeg not available');
      return;
    }

    final dir = await Directory.systemTemp.createTemp('autozoom_test_');
    addTearDown(() => dir.delete(recursive: true));
    final input = p.join(dir.path, 'in.mp4');
    final made = await Process.run(ffmpeg, [
      '-y', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30', '-t', '6',
      '-pix_fmt', 'yuv420p', '-c:v', 'libx264', '-preset', 'ultrafast', input,
    ]);
    expect(made.exitCode, 0, reason: made.stderr.toString());

    final log = _circleLog(width: 640, height: 360, seconds: 6, clickTimes: [1.5]);
    final out = await applyAutoZoom(
      inputPath: input,
      log: log,
      width: 640,
      height: 360,
      encoder: 'libx264',
    );
    expect(p.basename(out), 'autozoom.mp4');
    expect(await File(out).length(), greaterThan(1000));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
