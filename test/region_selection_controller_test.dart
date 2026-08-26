import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/controllers/region_selection_controller.dart';

void main() {
  test('live create keeps the default hole until the drag is a few pixels', () {
    final controller = RegionSelectionController()
      ..keepRegionUntilDrag = true
      ..setOverlaySize(const Size(800, 600));
    final original = controller.region!;
    expect(original.width, greaterThan(4));

    controller.pointerDown(const Offset(20, 20));
    expect(controller.region, original);

    controller.pointerMove(const Offset(21, 21));
    expect(controller.region, original);

    controller.pointerUp(const Offset(21, 21));
    expect(controller.region, original);
  });

  test('live create replaces the hole once the drag exceeds the threshold', () {
    final controller = RegionSelectionController()
      ..keepRegionUntilDrag = true
      ..setOverlaySize(const Size(800, 600));

    controller.pointerDown(const Offset(20, 20));
    controller.pointerMove(const Offset(140, 160));
    controller.pointerUp(const Offset(140, 160));

    expect(controller.region, isNotNull);
    expect(controller.region!.left, closeTo(20, 0.5));
    expect(controller.region!.top, closeTo(20, 0.5));
    expect(controller.region!.width, closeTo(120, 0.5));
    expect(controller.region!.height, closeTo(140, 0.5));
  });

  test('snapshot create still starts from an empty rect', () {
    final controller = RegionSelectionController()
      ..setOverlaySize(const Size(800, 600));
    controller.pointerDown(const Offset(20, 20));
    expect(controller.region, const Rect.fromLTWH(20, 20, 0, 0));
  });
}
