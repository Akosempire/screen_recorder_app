import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// What sits behind the recording.
enum BackgroundKind { none, preset, image, color }

/// Built-in backgrounds: gradients and simple patterns. Painted at any size
/// with [paintBackgroundPreset], so the preview and the export match.
enum BackgroundPreset {
  ocean('Ocean'),
  sunset('Sunset'),
  mint('Mint'),
  peach('Peach'),
  sky('Sky'),
  lilac('Lilac'),
  coral('Coral'),
  forest('Forest'),
  gold('Gold'),
  slate('Slate'),
  night('Night'),
  dots('Dots'),
  grid('Grid'),
  stripes('Stripes');

  const BackgroundPreset(this.label);
  final String label;
}

/// Ready-made solid colours (ARGB). Any other colour can be picked too.
const List<int> backgroundSwatches = [
  0xFFFFFFFF, 0xFFF3F4F6, 0xFF111827, 0xFF000000,
  0xFF1D4ED8, 0xFF0EA5E9, 0xFF10B981, 0xFF84CC16,
  0xFFFACC15, 0xFFF97316, 0xFFEF4444, 0xFFEC4899,
  0xFF8B5CF6, 0xFF7C2D12,
];

/// A background choice plus how the recording is framed on it.
@immutable
class BackgroundSpec {
  const BackgroundSpec({
    this.kind = BackgroundKind.none,
    this.preset = BackgroundPreset.ocean,
    this.imagePath,
    this.color = defaultColor,
    this.padding = defaultPadding,
    this.radius = defaultRadius,
    this.shadow = true,
  });

  static const int defaultColor = 0xFF111827;
  static const double defaultPadding = 0.08;
  static const double minPadding = 0.03;
  static const double maxPadding = 0.16;
  static const double defaultRadius = 18;
  static const double maxRadius = 40;

  final BackgroundKind kind;
  final BackgroundPreset preset;

  /// Uploaded picture (PNG / JPG / WebP), used when [kind] is image.
  final String? imagePath;

  /// Solid colour (ARGB, always opaque), used when [kind] is color.
  final int color;

  /// Space around the recording, as a fraction of the video width.
  final double padding;

  /// Corner radius in pixels at 1080p; scaled with the output height.
  final double radius;

  final bool shadow;

  /// True when the export should draw a background.
  bool get isActive => switch (kind) {
        BackgroundKind.none => false,
        BackgroundKind.preset => true,
        BackgroundKind.color => true,
        BackgroundKind.image => imagePath != null && File(imagePath!).existsSync(),
      };

  String get label => switch (kind) {
        BackgroundKind.none => 'None',
        BackgroundKind.preset => preset.label,
        BackgroundKind.image => 'Your image',
        BackgroundKind.color => 'Colour ${colorHex(color)}',
      };
}

/// Where the recording goes inside a [width]×[height] frame.
/// All values are even, as H.264 with 4:2:0 colour needs.
@immutable
class BackgroundLayout {
  const BackgroundLayout({
    required this.width,
    required this.height,
    required this.x,
    required this.y,
    required this.innerWidth,
    required this.innerHeight,
    required this.radius,
  });

  final int width;
  final int height;
  final int x;
  final int y;
  final int innerWidth;
  final int innerHeight;
  final double radius;

  Rect get inner => Rect.fromLTWH(
        x.toDouble(),
        y.toDouble(),
        innerWidth.toDouble(),
        innerHeight.toDouble(),
      );

  RRect get innerRRect => RRect.fromRectAndRadius(inner, Radius.circular(radius));
}

/// '#RRGGBB' for an ARGB colour.
String colorHex(int argb) => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Reads '#RGB', '#RRGGBB' or 'RRGGBB' into an opaque ARGB colour, or null.
int? parseColorHex(String text) {
  var t = text.trim().replaceFirst('#', '');
  if (RegExp(r'^[0-9a-fA-F]{3}$').hasMatch(t)) t = t.split('').map((c) => '$c$c').join();
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(t)) return null;
  return 0xFF000000 | int.parse(t, radix: 16);
}

int _even(num v) => math.max(2, (v / 2).round() * 2);

/// Fits the recording inside the frame with [BackgroundSpec.padding] on the
/// sides, keeping its aspect ratio and centring it.
BackgroundLayout layoutBackground(int width, int height, BackgroundSpec spec) {
  final padding = spec.padding.clamp(BackgroundSpec.minPadding, BackgroundSpec.maxPadding).toDouble();
  final innerWidth = _even(width * (1 - 2 * padding));
  final innerHeight = _even(innerWidth * height / width);
  return BackgroundLayout(
    width: width,
    height: height,
    x: _even((width - innerWidth) / 2),
    y: _even((height - innerHeight) / 2),
    innerWidth: innerWidth,
    innerHeight: innerHeight,
    radius: spec.radius.clamp(0.0, BackgroundSpec.maxRadius).toDouble() * height / 1080,
  );
}

/// Paints a built-in background filling [size].
void paintBackgroundPreset(Canvas canvas, Size size, BackgroundPreset preset) {
  final rect = Offset.zero & size;
  final unit = math.min(size.width, size.height);
  Paint linear(List<Color> colors, {List<double>? stops}) => Paint()
    ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, colors, stops);

  switch (preset) {
    case BackgroundPreset.ocean:
      canvas.drawRect(rect, linear(const [Color(0xFF190096), Color(0xFF0080FF), Color(0xFF78D2FF)], stops: const [0, .55, 1]));
    case BackgroundPreset.sunset:
      canvas.drawRect(rect, linear(const [Color(0xFFFFB25B), Color(0xFFFF4D6D), Color(0xFF7B2FF7)], stops: const [0, .5, 1]));
    case BackgroundPreset.mint:
      canvas.drawRect(rect, linear(const [Color(0xFFC6F7E2), Color(0xFF43C59E), Color(0xFF0B7A75)], stops: const [0, .55, 1]));
    case BackgroundPreset.peach:
      canvas.drawRect(rect, linear(const [Color(0xFFFFF1E0), Color(0xFFFFD3C4), Color(0xFFF7B5CA)], stops: const [0, .5, 1]));
    case BackgroundPreset.sky:
      canvas.drawRect(rect, linear(const [Color(0xFFE0F2FE), Color(0xFF7DD3FC), Color(0xFF38BDF8)], stops: const [0, .55, 1]));
    case BackgroundPreset.lilac:
      canvas.drawRect(rect, linear(const [Color(0xFFF5E8FF), Color(0xFFC4B5FD), Color(0xFF8B5CF6)], stops: const [0, .55, 1]));
    case BackgroundPreset.coral:
      canvas.drawRect(rect, linear(const [Color(0xFFFFE4D6), Color(0xFFFF8A65), Color(0xFFE11D48)], stops: const [0, .5, 1]));
    case BackgroundPreset.forest:
      canvas.drawRect(rect, linear(const [Color(0xFF0F3D2E), Color(0xFF166534), Color(0xFF65A30D)], stops: const [0, .55, 1]));
    case BackgroundPreset.gold:
      canvas.drawRect(rect, linear(const [Color(0xFFFFF7D6), Color(0xFFFCD34D), Color(0xFFD97706)], stops: const [0, .5, 1]));
    case BackgroundPreset.slate:
      canvas.drawRect(rect, linear(const [Color(0xFF475569), Color(0xFF1E293B), Color(0xFF0F172A)], stops: const [0, .55, 1]));
    case BackgroundPreset.night:
      canvas.drawRect(rect, Paint()..color = const Color(0xFF0B0D1A));
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(size.width * .75, size.height * .2),
            unit * 1.1,
            const [Color(0xFF4B3FD1), Color(0x004B3FD1)],
          ),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(size.width * .15, size.height * .95),
            unit * .9,
            const [Color(0xAA0E7AC4), Color(0x000E7AC4)],
          ),
      );
    case BackgroundPreset.dots:
      canvas.drawRect(rect, linear(const [Color(0xFF151A2C), Color(0xFF0D1020)]));
      final gap = unit * .045;
      final dot = Paint()..color = const Color(0x3DFFFFFF);
      for (var y = gap / 2; y < size.height; y += gap) {
        for (var x = gap / 2; x < size.width; x += gap) {
          canvas.drawCircle(Offset(x, y), unit * .0042, dot);
        }
      }
    case BackgroundPreset.grid:
      canvas.drawRect(rect, linear(const [Color(0xFFF7F7F9), Color(0xFFEDEEF2)]));
      final gap = unit * .06;
      final line = Paint()
        ..color = const Color(0xFFDADCE3)
        ..strokeWidth = math.max(1, unit * .0018);
      for (var x = gap; x < size.width; x += gap) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
      }
      for (var y = gap; y < size.height; y += gap) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      }
    case BackgroundPreset.stripes:
      canvas.drawRect(rect, Paint()..color = const Color(0xFF1E2A4A));
      final gap = unit * .07;
      final stripe = Paint()
        ..color = const Color(0xFF26355E)
        ..strokeWidth = gap / 2;
      final span = size.width + size.height;
      for (var d = -size.height; d < span; d += gap) {
        canvas.drawLine(Offset(d, size.height), Offset(d + size.height, 0), stripe);
      }
  }
}

/// Paints [spec]'s colour or preset filling [size] (images are drawn separately).
void paintBackground(Canvas canvas, Size size, BackgroundSpec spec) {
  if (spec.kind == BackgroundKind.color) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Color(spec.color | 0xFF000000));
  } else {
    paintBackgroundPreset(canvas, size, spec.preset);
  }
}

/// Draws [image] covering [size] (cropped, centred, aspect kept).
void paintCoverImage(Canvas canvas, Size size, ui.Image image) {
  final src = Size(image.width.toDouble(), image.height.toDouble());
  final fitted = applyBoxFit(BoxFit.cover, src, size);
  final srcRect = Alignment.center.inscribe(fitted.source, Offset.zero & src);
  canvas.drawImageRect(
    image,
    srcRect,
    Offset.zero & size,
    Paint()..filterQuality = FilterQuality.high,
  );
}

/// Soft drop shadow under [rrect], scaled to the frame [height].
void paintRecordingShadow(Canvas canvas, RRect rrect, double height) {
  canvas.drawRRect(
    rrect.shift(Offset(0, height * .012)),
    Paint()
      ..color = const Color(0x59000000)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, height * .022),
  );
}

Future<ui.Image> loadImageFile(String path) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// Renders the export overlay: the background (and shadow) with a transparent
/// rounded window where the recording shows through. Returns PNG bytes.
Future<Uint8List> renderBackgroundFrame(BackgroundLayout layout, BackgroundSpec spec) async {
  final size = Size(layout.width.toDouble(), layout.height.toDouble());
  ui.Image? picture;
  if (spec.kind == BackgroundKind.image && spec.imagePath != null) {
    picture = await loadImageFile(spec.imagePath!);
  }
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  canvas.saveLayer(Offset.zero & size, Paint());
  if (picture != null) {
    paintCoverImage(canvas, size, picture);
  } else {
    paintBackground(canvas, size, spec);
  }
  if (spec.shadow) paintRecordingShadow(canvas, layout.innerRRect, size.height);
  canvas.drawRRect(layout.innerRRect, Paint()..blendMode = BlendMode.clear);
  canvas.restore();
  final image = await recorder.endRecording().toImage(layout.width, layout.height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture?.dispose();
  if (data == null) throw StateError('Could not encode the background.');
  return data.buffer.asUint8List();
}
