import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/models/display_server.dart';
import 'package:screen_recorder_app/models/screen_region.dart';

void main() {
  group('ScreenRegion', () {
    test('accepts a valid rectangle', () {
      const region = ScreenRegion(x: 10, y: 20, width: 1280, height: 720);
      expect(region.isValid, isTrue);
      expect(region.right, 1290);
      expect(region.bottom, 740);
    });

    test('rejects sizes below the 100×100 minimum', () {
      const region = ScreenRegion(x: 0, y: 0, width: 80, height: 100);
      expect(region.isValid, isFalse);
    });

    test('moves without changing size, including onto negative monitors', () {
      const region = ScreenRegion(x: 100, y: 50, width: 200, height: 200);
      final moved = region.moved(-1920, 0);
      expect(moved.x, -1820);
      expect(moved.y, 50);
      expect(moved.width, 200);
      expect(moved.height, 200);
    });

    test('resize from the left enforces minimum width', () {
      const region = ScreenRegion(x: 200, y: 200, width: 300, height: 300);
      final resized = region.resized(left: 450);
      expect(resized.width, ScreenRegion.minWidth);
      expect(resized.right, 500);
    });

    test('resize from the top-left keeps a usable rectangle', () {
      const region = ScreenRegion(x: 100, y: 100, width: 400, height: 400);
      final resized = region.resized(left: 80, top: 60);
      expect(resized.x, 80);
      expect(resized.y, 60);
      expect(resized.width, 420);
      expect(resized.height, 440);
    });

    test('clamp keeps the region inside bounds with negative origin', () {
      const bounds = ScreenRegion(x: -1920, y: 0, width: 3840, height: 1080);
      const region = ScreenRegion(x: -2000, y: -20, width: 200, height: 200);
      final clamped = region.clampedTo(bounds);
      expect(clamped.x, -1920);
      expect(clamped.y, 0);
      expect(clamped.width, 200);
      expect(clamped.height, 200);
    });

    test('clamp shrinks when the region is larger than the bounds', () {
      const bounds = ScreenRegion(x: 0, y: 0, width: 800, height: 600);
      const region = ScreenRegion(x: 0, y: 0, width: 1920, height: 1080);
      final clamped = region.clampedTo(bounds);
      expect(clamped.width, 800);
      expect(clamped.height, 600);
      expect(clamped.x, 0);
      expect(clamped.y, 0);
    });

    test('evenAlign rounds dimensions down to even values for H.264', () {
      const region = ScreenRegion(x: 11, y: 13, width: 321, height: 199);
      final even = region.evenAligned();
      expect(even.width.isEven, isTrue);
      expect(even.height.isEven, isTrue);
      expect(even.width, 320);
      expect(even.height, 198);
      expect(even.x, 11);
      expect(even.y, 13);
    });
  });

  group('DesktopGeometry mapping', () {
    test('maps overlay logical rect onto negative desktop coordinates', () {
      final geometry = DesktopGeometry.fromMonitors(
        displayServer: DisplayServer.x11,
        displayName: ':0',
        monitors: const [
          MonitorInfo(
            name: 'HDMI-1',
            x: -1920,
            y: 0,
            width: 1920,
            height: 1080,
            primary: false,
          ),
          MonitorInfo(
            name: 'eDP-1',
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            primary: true,
          ),
        ],
      );
      expect(geometry.minX, -1920);
      expect(geometry.width, 3840);
      expect(geometry.height, 1080);

      final mapped = geometry.mapOverlayRect(
        const RectLike(left: 0, top: 0, width: 400, height: 300),
        const SizeLike(width: 800, height: 300),
      );
      expect(mapped.x, -1920);
      expect(mapped.y, 0);
      expect(mapped.width, 1920);
      expect(mapped.height, 1080);
    });
  });
}
