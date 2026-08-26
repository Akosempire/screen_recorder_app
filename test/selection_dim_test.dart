import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/widgets/selection_rectangle.dart';

void main() {
  test('empty region dims the full overlay', () {
    const size = Size(800, 600);
    expect(
      selectionDimRects(size: size, region: null),
      [const Rect.fromLTWH(0, 0, 800, 600)],
    );
    expect(
      selectionDimRects(size: size, region: Rect.zero),
      [const Rect.fromLTWH(0, 0, 800, 600)],
    );
  });

  test('a selection is dimmed with four rects and an undimmed hole', () {
    const size = Size(800, 600);
    const region = Rect.fromLTWH(100, 80, 200, 150);
    final rects = selectionDimRects(size: size, region: region);
    expect(rects, hasLength(4));
    expect(rects, isNot(contains(region)));

    const holeCenter = Offset(200, 155);
    for (final rect in rects) {
      expect(rect.contains(holeCenter), isFalse);
    }
    expect(rects.any((r) => r.contains(const Offset(10, 10))), isTrue);
  });
}
