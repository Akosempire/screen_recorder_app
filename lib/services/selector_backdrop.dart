import '../models/display_server.dart';
import 'linux_desktop.dart';

/// Compile-time kill switch. Live hole stays off until Phase 4/5 are proven
/// on a given X11 + compositor machine:
/// `flutter run -d linux --dart-define=LIVE_SELECTOR=1`
const bool kLiveSelectorEnabled =
    bool.fromEnvironment('LIVE_SELECTOR', defaultValue: false);

enum SelectorBackdrop {
  snapshot,
  liveHole,
}

/// One-time native probe of compositor punch-through (not the recording chip).
class AlphaProbe {
  const AlphaProbe({
    required this.composited,
    required this.hasRgbaVisual,
    required this.opaqueRegionSupported,
    this.nativeDisplayServer,
    this.glHasAlpha = false,
    this.probePassed = false,
  });

  static const AlphaProbe unavailable = AlphaProbe(
    composited: false,
    hasRgbaVisual: false,
    opaqueRegionSupported: false,
  );

  final bool composited;
  final bool hasRgbaVisual;
  final bool opaqueRegionSupported;
  final DisplayServer? nativeDisplayServer;
  final bool glHasAlpha;

  /// Cached native result. Prefer this over re-deriving from the fields so a
  /// failed GTK probe cannot be "fixed" in Dart.
  final bool probePassed;

  bool get passed =>
      probePassed ||
      (composited && hasRgbaVisual && opaqueRegionSupported);
}

/// Chooses the selector backend **before** the overlay maps.
///
/// Never inferred from "did this frame look right?"
SelectorBackdrop chooseBackdrop({
  required DisplayServer displayServer,
  required bool isGnome,
  required bool isWlroots,
  required bool composited,
  required bool probePassed,
  bool liveSelectorEnabled = kLiveSelectorEnabled,
}) {
  if (!liveSelectorEnabled) {
    return SelectorBackdrop.snapshot;
  }

  // GNOME/Unity + Wayland stays on the snapshot + portal path.
  if (displayServer == DisplayServer.wayland && isGnome) {
    return SelectorBackdrop.snapshot;
  }

  // No compositor: x11grab snapshot, not a hole in an unredirected window.
  if (displayServer == DisplayServer.x11 && !composited) {
    return SelectorBackdrop.snapshot;
  }

  // XWayland-only / unknown: do not pretend we have a native hole.
  if (displayServer == DisplayServer.unknown) {
    return SelectorBackdrop.snapshot;
  }

  // wlroots Wayland: snapshot until layer-shell / opaque-region exists.
  if (displayServer == DisplayServer.wayland || isWlroots) {
    return SelectorBackdrop.snapshot;
  }

  if (displayServer == DisplayServer.x11 && composited && probePassed) {
    return SelectorBackdrop.liveHole;
  }

  return SelectorBackdrop.snapshot;
}

SelectorBackdrop chooseSelectorBackdrop({
  required DesktopGeometry geometry,
  required AlphaProbe probe,
  bool liveSelectorEnabled = kLiveSelectorEnabled,
  bool? isGnome,
  bool? isWlroots,
}) {
  return chooseBackdrop(
    displayServer: geometry.displayServer,
    isGnome: isGnome ?? LinuxDesktop.isGnome,
    isWlroots: isWlroots ?? LinuxDesktop.isWlroots,
    composited: probe.composited,
    probePassed: probe.passed,
    liveSelectorEnabled: liveSelectorEnabled,
  );
}
