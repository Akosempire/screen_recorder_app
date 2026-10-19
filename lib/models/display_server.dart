import 'screen_region.dart';

enum DisplayServer {
  x11,
  wayland,

  /// Windows desktop (GDI capture via FFmpeg gdigrab).
  windows,

  /// macOS main display (FFmpeg avfoundation).
  macos,
  unknown,
}

class MonitorInfo {
  final String name;
  final int x;
  final int y;
  final int width;
  final int height;
  final bool primary;
  final double scaleFactor;

  const MonitorInfo({
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.primary = false,
    this.scaleFactor = 1.0,
  });

  int get right => x + width;
  int get bottom => y + height;

  @override
  String toString() =>
      'MonitorInfo($name ${width}x$height+$x+$y primary=$primary scale=$scaleFactor)';
}

/// Physical desktop layout: monitor list plus the bounding box used by capture.
class DesktopGeometry {
  final DisplayServer displayServer;
  final String? displayName;
  final List<MonitorInfo> monitors;
  final int minX;
  final int minY;
  final int width;
  final int height;
  final String? waylandDisplay;

  const DesktopGeometry({
    required this.displayServer,
    required this.monitors,
    required this.minX,
    required this.minY,
    required this.width,
    required this.height,
    this.displayName,
    this.waylandDisplay,
  });

  int get maxX => minX + width;
  int get maxY => minY + height;

  bool get isEmpty => monitors.isEmpty || width <= 0 || height <= 0;

  ScreenRegion get bounds => ScreenRegion(
        x: minX,
        y: minY,
        width: width,
        height: height,
      );

  factory DesktopGeometry.fromMonitors({
    required DisplayServer displayServer,
    required List<MonitorInfo> monitors,
    String? displayName,
    String? waylandDisplay,
  }) {
    if (monitors.isEmpty) {
      return DesktopGeometry(
        displayServer: displayServer,
        monitors: const [],
        minX: 0,
        minY: 0,
        width: 0,
        height: 0,
        displayName: displayName,
        waylandDisplay: waylandDisplay,
      );
    }
    final minX = monitors.map((m) => m.x).reduce((a, b) => a < b ? a : b);
    final minY = monitors.map((m) => m.y).reduce((a, b) => a < b ? a : b);
    final maxX = monitors.map((m) => m.right).reduce((a, b) => a > b ? a : b);
    final maxY = monitors.map((m) => m.bottom).reduce((a, b) => a > b ? a : b);
    return DesktopGeometry(
      displayServer: displayServer,
      monitors: List<MonitorInfo>.unmodifiable(monitors),
      minX: minX,
      minY: minY,
      width: maxX - minX,
      height: maxY - minY,
      displayName: displayName,
      waylandDisplay: waylandDisplay,
    );
  }

  /// Map a Flutter overlay-local logical rectangle onto real desktop pixels.
  ///
  /// The overlay is assumed to cover [bounds] visually. Using a proportional
  /// map avoids depending on devicePixelRatio matching X11/Wayland pixels.
  ScreenRegion mapOverlayRect(RectLike local, SizeLike overlaySize) {
    if (overlaySize.width <= 0 || overlaySize.height <= 0) {
      throw StateError('Overlay size must be positive');
    }
    final x = minX + (local.left / overlaySize.width) * width;
    final y = minY + (local.top / overlaySize.height) * height;
    final w = (local.width / overlaySize.width) * width;
    final h = (local.height / overlaySize.height) * height;
    return ScreenRegion(
      x: x.round(),
      y: y.round(),
      width: w.round().clamp(1, width),
      height: h.round().clamp(1, height),
    ).evenAligned().clampedTo(bounds);
  }
}

/// Minimal geometry types so this model file does not import Flutter.
class RectLike {
  final double left;
  final double top;
  final double width;
  final double height;

  const RectLike({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

class SizeLike {
  final double width;
  final double height;

  const SizeLike({required this.width, required this.height});
}
