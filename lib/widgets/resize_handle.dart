import 'package:flutter/material.dart';

class ResizeHandleWidget extends StatelessWidget {
  const ResizeHandleWidget({
    super.key,
    required this.rect,
    this.active = false,
  });

  final Rect rect;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: active ? const Color(0xFFFF6B6B) : Colors.white,
            border: Border.all(color: const Color(0xFFE53935), width: 1.5),
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ),
    );
  }
}
