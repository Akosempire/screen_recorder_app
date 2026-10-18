import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/recording_options.dart';
import 'studio_theme.dart';

/// A tiny "someone's desktop" scene used behind tile and tour previews.
void paintMiniDesktop(Canvas canvas, Size size) {
  final rect = Offset.zero & size;
  canvas.drawRect(
    rect,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF3B6EA8), Color(0xFF5B8FC4)],
      ).createShader(rect),
  );
  final window = Rect.fromLTWH(
    size.width * 0.08,
    size.height * 0.12,
    size.width * 0.84,
    size.height * 0.80,
  );
  final r = Radius.circular(size.shortestSide * 0.05);
  canvas.drawRRect(RRect.fromRectAndRadius(window, r), Paint()..color = const Color(0xFFF7F7F8));
  canvas.drawRRect(
    RRect.fromRectAndCorners(
      Rect.fromLTWH(window.left, window.top, window.width, window.height * 0.13),
      topLeft: r,
      topRight: r,
    ),
    Paint()..color = const Color(0xFFE2E4E8),
  );
  final line = Paint()..color = const Color(0xFFD3D6DC);
  for (var i = 0; i < 4; i++) {
    final y = window.top + window.height * (0.26 + i * 0.13);
    final w = window.width * (i.isEven ? 0.62 : 0.44);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(window.left + window.width * 0.07, y, w, window.height * 0.055),
        const Radius.circular(2),
      ),
      line,
    );
  }
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(
        window.left + window.width * 0.07,
        window.top + window.height * 0.78,
        window.width * 0.22,
        window.height * 0.11,
      ),
      const Radius.circular(3),
    ),
    Paint()..color = const Color(0xFF2F6FD6),
  );
}

void paintArrowCursor(Canvas canvas, Offset tip, double scale) {
  final path = Path()
    ..moveTo(tip.dx, tip.dy)
    ..lineTo(tip.dx, tip.dy + 17 * scale)
    ..lineTo(tip.dx + 4.2 * scale, tip.dy + 13 * scale)
    ..lineTo(tip.dx + 7 * scale, tip.dy + 19.5 * scale)
    ..lineTo(tip.dx + 9.6 * scale, tip.dy + 18.4 * scale)
    ..lineTo(tip.dx + 6.9 * scale, tip.dy + 12.2 * scale)
    ..lineTo(tip.dx + 12.4 * scale, tip.dy + 12.2 * scale)
    ..close();
  canvas.drawPath(path, Paint()..color = Colors.white);
  canvas.drawPath(
    path,
    Paint()
      ..color = const Color(0xFF111111)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1 * scale
      ..strokeJoin = StrokeJoin.round,
  );
}

/// Tile preview for a [CursorStyle].
class CursorStylePainter extends CustomPainter {
  const CursorStylePainter(this.style);

  final CursorStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    paintMiniDesktop(canvas, size);
    final scale = size.shortestSide / 70;
    final center = Offset(size.width * 0.56, size.height * 0.56);
    if (style.drawsRipples) {
      for (final (radius, alpha) in [(22.0, 0.35), (15.0, 0.7)]) {
        canvas.drawCircle(
          center,
          radius * scale,
          Paint()
            ..color = Studio.highlight.withValues(alpha: alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * scale,
        );
      }
    }
    if (style.drawsHalo) {
      canvas.drawCircle(
        center,
        10 * scale,
        Paint()..color = Studio.highlight.withValues(alpha: 0.35),
      );
      canvas.drawCircle(
        center,
        10 * scale,
        Paint()
          ..color = Studio.highlight
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 * scale,
      );
    }
    paintArrowCursor(canvas, center, scale * 0.9);
  }

  @override
  bool shouldRepaint(CursorStylePainter oldDelegate) => oldDelegate.style != style;
}

/// Empty-stage illustration: a dashed capture box over a window.
class EmptyStagePainter extends CustomPainter {
  const EmptyStagePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(14),
    );
    canvas.save();
    canvas.clipRRect(rrect);
    paintMiniDesktop(canvas, size);
    canvas.restore();

    final box = Rect.fromLTWH(
      size.width * 0.22,
      size.height * 0.30,
      size.width * 0.56,
      size.height * 0.48,
    );
    canvas.drawRect(box, Paint()..color = const Color(0x14E5483B));
    _dashedRect(canvas, box, Studio.record, 2);
    for (final corner in [box.topLeft, box.topRight, box.bottomLeft, box.bottomRight]) {
      canvas.drawCircle(corner, 5, Paint()..color = Colors.white);
      canvas.drawCircle(
        corner,
        5,
        Paint()
          ..color = Studio.record
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final scale = size.shortestSide / 120;
    final c = Offset(box.right - box.width * 0.18, box.bottom - box.height * 0.28);
    canvas.drawCircle(c, 13 * scale, Paint()..color = Studio.highlight.withValues(alpha: 0.35));
    canvas.drawCircle(
      c,
      13 * scale,
      Paint()
        ..color = Studio.highlight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * scale,
    );
    paintArrowCursor(canvas, c, scale);
  }

  static void _dashedRect(Canvas canvas, Rect rect, Color color, double width) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    const dash = 7.0;
    const gap = 5.0;
    void line(Offset a, Offset b) {
      final total = (b - a).distance;
      final dir = (b - a) / total;
      var d = 0.0;
      while (d < total) {
        final end = math.min(d + dash, total);
        canvas.drawLine(a + dir * d, a + dir * end, paint);
        d += dash + gap;
      }
    }

    line(rect.topLeft, rect.topRight);
    line(rect.topRight, rect.bottomRight);
    line(rect.bottomRight, rect.bottomLeft);
    line(rect.bottomLeft, rect.topLeft);
  }

  @override
  bool shouldRepaint(EmptyStagePainter oldDelegate) => false;
}

/// Zoom illustration for the tour: a zoomed crop with a cursor.
class ZoomIllustrationPainter extends CustomPainter {
  const ZoomIllustrationPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(-size.width * 0.35, -size.height * 0.4);
    canvas.scale(1.7);
    paintMiniDesktop(canvas, size);
    canvas.restore();
    final c = Offset(size.width * 0.55, size.height * 0.55);
    final s = size.shortestSide / 60;
    canvas.drawCircle(c, 10 * s, Paint()..color = Studio.highlight.withValues(alpha: 0.35));
    paintArrowCursor(canvas, c, s);
    final frame = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    const k = 14.0;
    final r = (Offset.zero & size).deflate(8);
    for (final (o, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(o, o + Offset(k * dx, 0), frame);
      canvas.drawLine(o, o + Offset(0, k * dy), frame);
    }
  }

  @override
  bool shouldRepaint(ZoomIllustrationPainter oldDelegate) => false;
}

/// Tour art for the face camera: a desktop with a round webcam bubble.
class CameraIllustrationPainter extends CustomPainter {
  const CameraIllustrationPainter();

  @override
  void paint(Canvas canvas, Size size) {
    paintMiniDesktop(canvas, size);
    final r = size.shortestSide * 0.30;
    final c = Offset(size.width * 0.20 + r * 0.2, size.height - r - 6);
    final clip = Path()..addOval(Rect.fromCircle(center: c, radius: r));
    canvas.save();
    canvas.clipPath(clip);
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF6D8FB3));
    // Shoulders and head.
    canvas.drawOval(
      Rect.fromCenter(
        center: c + Offset(0, r * 0.95),
        width: r * 1.7,
        height: r * 1.2,
      ),
      Paint()..color = const Color(0xFF2B3A4D),
    );
    canvas.drawCircle(
      c + Offset(0, -r * 0.12),
      r * 0.36,
      Paint()..color = const Color(0xFFE2B48C),
    );
    canvas.restore();
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(CameraIllustrationPainter oldDelegate) => false;
}
