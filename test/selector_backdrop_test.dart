import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/models/display_server.dart';
import 'package:screen_recorder_app/services/selector_backdrop.dart';

void main() {
  const x11 = DisplayServer.x11;
  const wayland = DisplayServer.wayland;
  const unknown = DisplayServer.unknown;

  group('chooseBackdrop', () {
    test('defaults to snapshot even on a passing X11 probe', () {
      expect(
        chooseBackdrop(
          displayServer: x11,
          isGnome: false,
          isWlroots: false,
          composited: true,
          probePassed: true,
        ),
        SelectorBackdrop.snapshot,
      );
    });

    test('GNOME Wayland stays snapshot even with the live flag and a probe', () {
      expect(
        chooseBackdrop(
          displayServer: wayland,
          isGnome: true,
          isWlroots: false,
          composited: true,
          probePassed: true,
          liveSelectorEnabled: true,
        ),
        SelectorBackdrop.snapshot,
      );
    });

    test('GNOME X11 + compositing + probe can be live when the flag is on', () {
      expect(
        chooseBackdrop(
          displayServer: x11,
          isGnome: true,
          isWlroots: false,
          composited: true,
          probePassed: true,
          liveSelectorEnabled: true,
        ),
        SelectorBackdrop.liveHole,
      );
    });

    test('X11 without a compositor stays snapshot', () {
      expect(
        chooseBackdrop(
          displayServer: x11,
          isGnome: false,
          isWlroots: false,
          composited: false,
          probePassed: true,
          liveSelectorEnabled: true,
        ),
        SelectorBackdrop.snapshot,
      );
    });

    test('X11 + compositor but failed probe stays snapshot', () {
      expect(
        chooseBackdrop(
          displayServer: x11,
          isGnome: false,
          isWlroots: false,
          composited: true,
          probePassed: false,
          liveSelectorEnabled: true,
        ),
        SelectorBackdrop.snapshot,
      );
    });

    test('wlroots Wayland stays snapshot until layer-shell exists', () {
      expect(
        chooseBackdrop(
          displayServer: wayland,
          isGnome: false,
          isWlroots: true,
          composited: true,
          probePassed: true,
          liveSelectorEnabled: true,
        ),
        SelectorBackdrop.snapshot,
      );
    });

    test('unknown display server stays snapshot', () {
      expect(
        chooseBackdrop(
          displayServer: unknown,
          isGnome: false,
          isWlroots: false,
          composited: true,
          probePassed: true,
          liveSelectorEnabled: true,
        ),
        SelectorBackdrop.snapshot,
      );
    });

    test('non-GNOME Wayland (XWayland-only / KDE) stays snapshot', () {
      expect(
        chooseBackdrop(
          displayServer: wayland,
          isGnome: false,
          isWlroots: false,
          composited: true,
          probePassed: true,
          liveSelectorEnabled: true,
        ),
        SelectorBackdrop.snapshot,
      );
    });
  });

  group('chooseSelectorBackdrop', () {
    const geometry = DesktopGeometry(
      displayServer: DisplayServer.x11,
      monitors: [
        MonitorInfo(
          name: 'eDP-1',
          x: 0,
          y: 0,
          width: 1920,
          height: 1080,
          primary: true,
        ),
      ],
      minX: 0,
      minY: 0,
      width: 1920,
      height: 1080,
    );

    test('uses the probe fields when native probePassed is unset', () {
      const probe = AlphaProbe(
        composited: true,
        hasRgbaVisual: true,
        opaqueRegionSupported: true,
        probePassed: true,
      );
      expect(
        chooseSelectorBackdrop(
          geometry: geometry,
          probe: probe,
          liveSelectorEnabled: true,
          isGnome: false,
          isWlroots: false,
        ),
        SelectorBackdrop.liveHole,
      );
    });
  });
}
