import 'package:flutter/material.dart';

import '../controllers/recording_controller.dart';
import '../models/recording_state.dart';

String formatElapsed(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

class RecordingControls extends StatelessWidget {
  const RecordingControls({
    super.key,
    required this.controller,
    required this.onPauseResume,
    required this.onStop,
  });

  final RecordingController controller;
  final VoidCallback onPauseResume;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final recording = controller.state == RecordingState.recording;
    final paused = controller.state == RecordingState.paused;
    final busy = controller.state.isBusy;

    return Material(
      color: const Color(0xF0161A20),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RecordingDot(active: recording),
            const SizedBox(width: 5),
            Text(
              formatElapsed(controller.elapsed),
              style: const TextStyle(
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
            if (controller.recordMicrophone) ...[
              const SizedBox(width: 6),
              const Icon(
                Icons.mic,
                size: 14,
                color: Color(0xFF26A69A),
              ),
            ],
            _TinyIconButton(
              tooltip: paused ? 'Resume' : 'Pause',
              icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              onPressed: busy ? null : onPauseResume,
            ),
            _TinyIconButton(
              tooltip: 'Stop',
              icon: Icons.stop_rounded,
              color: const Color(0xFFE53935),
              onPressed: busy ? null : onStop,
            ),
          ],
        ),
      ),
    );
  }
}

class _TinyIconButton extends StatelessWidget {
  const _TinyIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color = Colors.white,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        color: color,
        disabledColor: color.withValues(alpha: 0.35),
        icon: Icon(icon),
      ),
    );
  }
}

class _RecordingDot extends StatefulWidget {
  const _RecordingDot({required this.active});

  final bool active;

  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.active) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _RecordingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.active && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: widget.active
          ? _pulse.drive(Tween(begin: 0.35, end: 1.0))
          : const AlwaysStoppedAnimation(1),
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          color: Color(0xFFE53935),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
