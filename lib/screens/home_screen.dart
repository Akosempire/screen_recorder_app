import 'package:flutter/material.dart';

import '../controllers/recording_controller.dart';
import '../models/recording_state.dart';
import '../services/recording_options.dart';

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
                        'Records any rectangle of your screen — other windows, a browser, a terminal — not this app.',
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
                      if (RecordingOptions.effectsSupported) ...[
                        const SizedBox(height: 16),
                        _EffectsPanel(enabled: enabled),
                      ],
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

/// Cursor highlight and auto-zoom switches (Windows backend).
class _EffectsPanel extends StatelessWidget {
  const _EffectsPanel({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final options = RecordingOptions.instance;
    return ListenableBuilder(
      listenable: options,
      builder: (context, _) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1D23),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF2A2F38)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: [
              _EffectSwitch(
                icon: Icons.ads_click_rounded,
                title: 'Cursor highlight',
                subtitle: 'Yellow halo + click ripples, live and in the video',
                value: options.cursorHighlight,
                onChanged: enabled ? (v) => options.cursorHighlight = v : null,
              ),
              const Divider(height: 1, color: Color(0xFF2A2F38)),
              _EffectSwitch(
                icon: Icons.zoom_in_map_rounded,
                title: 'Auto-zoom follows mouse',
                subtitle: 'Zooms in on clicks and pans with the cursor',
                value: options.autoZoom,
                onChanged: enabled ? (v) => options.autoZoom = v : null,
              ),
              if (options.autoZoom)
                Padding(
                  padding: const EdgeInsets.only(left: 34, bottom: 4),
                  child: Row(
                    children: [
                      const Text(
                        'Zoom',
                        style: TextStyle(fontSize: 12, color: Color(0xFFB0BEC5)),
                      ),
                      Expanded(
                        child: Slider(
                          value: options.zoomLevel,
                          min: 1.2,
                          max: 3.0,
                          divisions: 18,
                          label: '${options.zoomLevel.toStringAsFixed(1)}×',
                          onChanged:
                              enabled ? (v) => options.zoomLevel = v : null,
                        ),
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${options.zoomLevel.toStringAsFixed(1)}×',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFB0BEC5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _EffectSwitch extends StatelessWidget {
  const _EffectSwitch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFFFFD600)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF8A939F),
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
