import 'package:flutter/material.dart';

import '../controllers/recording_controller.dart';
import '../models/recording_state.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.onStartRecording,
  });

  final RecordingController controller;
  final VoidCallback onStartRecording;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = controller.errorMessage;
    final enabled = controller.canBeginSelection && !controller.state.isBusy;

    return Scaffold(
      backgroundColor: const Color(0xFF121418),
      body: LayoutBuilder(
        builder: (context, constraints) {
          const padding = EdgeInsets.fromLTRB(24, 20, 24, 16);
          return SingleChildScrollView(
            padding: padding,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - padding.vertical)
                    .clamp(0, double.infinity),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.videocam_rounded,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Screen Recorder',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Records any rectangle of your desktop — other windows, a browser, a terminal — not this app.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFFB0BEC5),
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: enabled ? onStartRecording : null,
                        icon: const Icon(Icons.fiber_manual_record, size: 18),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Text('Start Recording'),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFE53935),
                          disabledBackgroundColor: const Color(0xFF4A3030),
                          foregroundColor: Colors.white,
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      _StatusRow(controller: controller),
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          error,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFFFF8A80),
                          ),
                        ),
                      ] else if (controller.statusDetail != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          controller.statusDetail!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFFB0BEC5),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    '${controller.backendName}  ·  Ctrl+Shift+R to start',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF6B7380),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.controller});

  final RecordingController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final color = switch (state) {
      RecordingState.error => const Color(0xFFE53935),
      RecordingState.completed => const Color(0xFF43A047),
      RecordingState.recording => const Color(0xFFE53935),
      _ => const Color(0xFF26A69A),
    };
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            'Status: ${state.label}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
