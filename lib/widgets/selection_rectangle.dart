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

class SelectionDimPainter extends CustomPainter {
  SelectionDimPainter({required this.region, required this.color});

  final Rect? region;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final full = Offset.zero & size;
    if (region == null || region!.isEmpty) {
      canvas.drawRect(full, paint);
      return;
    }
    // Draw four rects around the selection. Do not use BlendMode.clear —
    // on Flutter Linux that often fills the hole with magenta.
    final r = region!;
    if (r.top > 0) {
      canvas.drawRect(Rect.fromLTRB(0, 0, size.width, r.top), paint);
    }
    if (r.bottom < size.height) {
      canvas.drawRect(
        Rect.fromLTRB(0, r.bottom, size.width, size.height),
        paint,
      );
    }
    if (r.left > 0) {
      canvas.drawRect(Rect.fromLTRB(0, r.top, r.left, r.bottom), paint);
    }
    if (r.right < size.width) {
      canvas.drawRect(
        Rect.fromLTRB(r.right, r.top, size.width, r.bottom),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(SelectionDimPainter oldDelegate) {
    return oldDelegate.region != region || oldDelegate.color != color;
  }
}
