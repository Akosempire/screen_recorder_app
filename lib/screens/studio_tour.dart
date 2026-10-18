import 'package:flutter/material.dart';

import '../services/recording_options.dart';
import '../ui/studio_painters.dart';
import '../ui/studio_theme.dart';
import '../ui/studio_widgets.dart';
import 'home_screen.dart';

class TourStep {
  const TourStep({
    required this.railIndex,
    required this.title,
    required this.body,
    required this.art,
    this.chip,
  });

  final int railIndex;
  final String title;
  final String body;
  final CustomPainter art;
  final String? chip;
}

final tourSteps = <TourStep>[
  const TourStep(
    railIndex: 0,
    title: 'Start a recording',
    body: 'Drag a box around any window or area. Press Stop when you are done. '
        'Everything stays on this PC.',
    art: EmptyStagePainter(),
    chip: 'Ctrl+Shift+R',
  ),
  const TourStep(
    railIndex: 1,
    title: 'Highlight your cursor',
    body: 'A yellow halo follows the mouse and clicks ripple, live on screen '
        'and in the video. Pick a style here.',
    art: CursorStylePainter(CursorStyle.haloAndRipples),
    chip: 'Halo + ripples',
  ),
  const TourStep(
    railIndex: 2,
    title: 'Auto-zoom follows the mouse',
    body: 'When you stop, the video zooms in where you clicked and pans with '
        'your cursor. Tune the zoom and smoothness.',
    art: ZoomIllustrationPainter(),
    chip: '1.8×',
  ),
  const TourStep(
    railIndex: 3,
    title: 'Show your face',
    body: 'Turn on Camera and your webcam floats in a round bubble. Drag it '
        'anywhere; it is recorded with your screen.',
    art: CameraIllustrationPainter(),
    chip: 'Camera',
  ),
  const TourStep(
    railIndex: 7,
    title: 'Export and find it later',
    body: 'Choose resolution, quality and sound, then save. Compare the '
        'original and zoomed versions with Before / After.',
    art: CursorStylePainter(CursorStyle.off),
    chip: 'MP4',
  ),
];

/// First-run walkthrough: a popover next to the rail item it explains.
class StudioTour extends StatefulWidget {
  const StudioTour({super.key, required this.onFinish, this.onStep});

  final VoidCallback onFinish;
  final ValueChanged<TourStep>? onStep;

  @override
  State<StudioTour> createState() => _StudioTourState();
}

class _StudioTourState extends State<StudioTour> {
  int _index = 0;

  void _next() {
    if (_index >= tourSteps.length - 1) {
      widget.onFinish();
      return;
    }
    setState(() => _index++);
    widget.onStep?.call(tourSteps[_index]);
  }

  @override
  Widget build(BuildContext context) {
    final step = tourSteps[_index];
    return LayoutBuilder(
      builder: (context, box) {
        const width = 372.0;
        const height = 300.0;
        final anchorY = HomeScreen.topBarHeight +
            1 +
            HomeScreen.railTopPadding +
            step.railIndex * HomeScreen.railItemExtent +
            HomeScreen.railItemExtent / 2;
        final maxTop = box.maxHeight - height - 8 < 8 ? 8.0 : box.maxHeight - height - 8;
        final top = (anchorY - 40).clamp(8.0, maxTop);
        final arrowY = (anchorY - top).clamp(20.0, height - 20);
        return Stack(
          children: [
            const Positioned.fill(
              child: ModalBarrier(color: Color(0x14000000), dismissible: false),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              left: HomeScreen.railWidth + 4,
              top: top,
              width: width + 10,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 4,
                    top: arrowY - 8,
                    child: Transform.rotate(
                      angle: 0.785398,
                      child: Container(
                        width: 16,
                        height: 16,
                        color: Studio.surface,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: _Card(
                      step: step,
                      index: _index,
                      count: tourSteps.length,
                      onSkip: widget.onFinish,
                      onNext: _next,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.step,
    required this.index,
    required this.count,
    required this.onSkip,
    required this.onNext,
  });

  final TourStep step;
  final int index;
  final int count;
  final VoidCallback onSkip;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final last = index == count - 1;
    return Container(
      decoration: BoxDecoration(
        color: Studio.surface,
        borderRadius: BorderRadius.circular(Studio.radiusLg),
        boxShadow: Studio.floating,
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 104,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F1F3),
              borderRadius: BorderRadius.circular(Studio.radius + 2),
            ),
            child: Row(
              children: [
                if (step.chip != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: Studio.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Studio.border),
                    ),
                    child: Text(step.chip!, style: StudioText.caption.copyWith(color: Studio.ink)),
                  ),
                const Spacer(),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 150,
                    height: 76,
                    child: CustomPaint(painter: step.art),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(step.body, style: StudioText.label.copyWith(color: Studio.muted, height: 1.45)),
                const SizedBox(height: 16),
                Row(
                  children: [
                    GestureDetector(
                      onTap: onSkip,
                      child: const MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Text('Skip tour', style: StudioText.caption),
                      ),
                    ),
                    const SizedBox(width: 16),
                    for (var i = 0; i < count; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: const EdgeInsets.only(right: 5),
                        width: i == index ? 20 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: i == index ? Studio.primary : const Color(0xFFD5D5D9),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    const Spacer(),
                    StudioPrimaryButton(label: last ? 'Done' : 'Next', onPressed: onNext),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
