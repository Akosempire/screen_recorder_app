import 'package:flutter/material.dart';

import '../controllers/region_selection_controller.dart';
import 'resize_handle.dart';

class SelectionRectangle extends StatelessWidget {
  const SelectionRectangle({
    super.key,
    required this.controller,
  });

  final RegionSelectionController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final region = controller.region;
        if (region == null) {
          return const SizedBox.shrink();
        }
        return Stack(
          children: [
            Positioned.fromRect(
              rect: region,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFFE53935),
                      width: 2,
                    ),
                  ),
                ),
              ),
            ),
            for (final handle in ResizeHandle.values)
              ResizeHandleWidget(
                rect: controller.handleRect(handle),
                active: controller.activeHandle == handle,
              ),
          ],
        );
      },
    );
  }
}

/// Four dim rects around [region]. Empty/null region dims the full overlay.
/// Never a hole via [BlendMode.clear] — that paints magenta on Flutter Linux.
List<Rect> selectionDimRects({required Size size, required Rect? region}) {
  if (region == null || region.isEmpty) {
    return [Offset.zero & size];
  }
  final rects = <Rect>[];
  final r = region;
  if (r.top > 0) {
    rects.add(Rect.fromLTRB(0, 0, size.width, r.top));
  }
  if (r.bottom < size.height) {
    rects.add(Rect.fromLTRB(0, r.bottom, size.width, size.height));
  }
  if (r.left > 0) {
    rects.add(Rect.fromLTRB(0, r.top, r.left, r.bottom));
  }
  if (r.right < size.width) {
    rects.add(Rect.fromLTRB(r.right, r.top, size.width, r.bottom));
  }
  return rects;
}

class SelectionDimPainter extends CustomPainter {
  SelectionDimPainter({required this.region, required this.color});

  final Rect? region;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (final rect in selectionDimRects(size: size, region: region)) {
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(SelectionDimPainter oldDelegate) {
    return oldDelegate.region != region || oldDelegate.color != color;
  }
}
