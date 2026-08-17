import 'dart:math' as math;
import 'dart:ui' show Rect;

/// A rectangle in real Linux desktop (pixel) coordinates.
///
/// Origin may be negative when a monitor sits to the left or above the
/// primary display. Values are intended for capture backends such as
/// FFmpeg `x11grab` or `wf-recorder`, not Flutter logical pixels.
class ScreenRegion {
  static const int minWidth = 100;
  static const int minHeight = 100;

  final int x;
  final int y;
  final int width;
  final int height;

  const ScreenRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  int get right => x + width;
  int get bottom => y + height;

  bool get isValid =>
      width >= minWidth && height >= minHeight && width > 0 && height > 0;

  Rect get rect => Rect.fromLTWH(
        x.toDouble(),
        y.toDouble(),
        width.toDouble(),
        height.toDouble(),
      );

  ScreenRegion copyWith({int? x, int? y, int? width, int? height}) {
    return ScreenRegion(
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
    );
  }

  /// Translate by [dx], [dy] without changing size.
  ScreenRegion moved(int dx, int dy) {
    return copyWith(x: x + dx, y: y + dy);
  }

  /// Resize from a given edge/corner while enforcing the minimum size.
  ScreenRegion resized({
    int? left,
    int? top,
    int? right,
    int? bottom,
  }) {
    var newLeft = left ?? x;
    var newTop = top ?? y;
    var newRight = right ?? this.right;
    var newBottom = bottom ?? this.bottom;

    if (newRight - newLeft < minWidth) {
      if (left != null && right == null) {
        newLeft = newRight - minWidth;
      } else {
        newRight = newLeft + minWidth;
      }
    }
    if (newBottom - newTop < minHeight) {
      if (top != null && bottom == null) {
        newTop = newBottom - minHeight;
      } else {
        newBottom = newTop + minHeight;
      }
    }

    return ScreenRegion(
      x: newLeft,
      y: newTop,
      width: newRight - newLeft,
      height: newBottom - newTop,
    );
  }

  /// Keep the rectangle inside [bounds]. Size is reduced only if the bounds
  /// themselves are smaller than the current rectangle.
  ScreenRegion clampedTo(ScreenRegion bounds) {
    var next = this;
    if (next.width > bounds.width) {
      next = next.copyWith(width: bounds.width, x: bounds.x);
    }
    if (next.height > bounds.height) {
      next = next.copyWith(height: bounds.height, y: bounds.y);
    }

    final clampedX = next.x.clamp(bounds.x, bounds.right - next.width);
    final clampedY = next.y.clamp(bounds.y, bounds.bottom - next.height);
    return next.copyWith(x: clampedX, y: clampedY);
  }

  /// H.264 / yuv420p require even frame dimensions.
  ScreenRegion evenAligned() {
    final evenW = math.max(minWidth, width - (width % 2));
    final evenH = math.max(minHeight, height - (height % 2));
    return copyWith(width: evenW, height: evenH);
  }

  @override
  bool operator ==(Object other) {
    return other is ScreenRegion &&
        other.x == x &&
        other.y == y &&
        other.width == width &&
        other.height == height;
  }

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'ScreenRegion($width×$height at $x,$y)';
}
