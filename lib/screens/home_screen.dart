import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../controllers/recording_controller.dart';
import '../models/recording_state.dart';
import '../services/recording_library.dart';
import '../services/recording_options.dart';
import '../ui/studio_painters.dart';
import '../ui/studio_theme.dart';
import '../ui/studio_widgets.dart';
import 'studio_tour.dart';

enum _ViewMode { before, compare, after }

enum _Section { cursor, zoom, audio }

/// Editor-style home screen: top bar, tool rail, preview stage with a
/// transport bar and timeline, settings inspector, and a status bar.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.onStartRecording,
  });

  final RecordingController controller;
  final VoidCallback onStartRecording;

  static const double topBarHeight = 64;
  static const double railWidth = 84;
  static const double railItemExtent = 70;
  static const double railTopPadding = 10;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  _ViewMode _mode = _ViewMode.after;
  _Section _section = _Section.cursor;
  final _sectionKeys = {
    for (final s in _Section.values) s: GlobalKey(),
  };

  RecordingOptions get _options => RecordingOptions.instance;
  RecordingLibrary get _library => RecordingLibrary.instance;

  void _focusSection(_Section section) {
    setState(() => _section = section);
    final ctx = _sectionKeys[section]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _showInFolder() async {
    final saved = _library.last?.savedPath;
    if (saved == null) return;
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', ['/select,', saved]);
      } else {
        await Process.start('xdg-open', [p.dirname(saved)]);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640 || constraints.maxHeight < 420) {
          return _CompactHome(
            controller: widget.controller,
            onStartRecording: widget.onStartRecording,
          );
        }
        return Theme(
          data: Studio.theme(Theme.of(context)),
          child: ListenableBuilder(
            listenable: Listenable.merge([_options, _library]),
            builder: (context, _) => _studio(context, constraints),
          ),
        );
      },
    );
  }

  Widget _studio(BuildContext context, BoxConstraints constraints) {
    final wide = constraints.maxWidth >= 900;
    final last = _library.last;
    final canCompare = last?.hasComparison ?? false;
    final mode = canCompare ? _mode : _ViewMode.after;
    final showTour = _options.loaded && !_options.tourDone;
    final enabled =
        widget.controller.canBeginSelection && !widget.controller.state.isBusy;

    return Scaffold(
      backgroundColor: Studio.chrome,
      body: Stack(
        children: [
          Column(
            children: [
              _TopBar(
                title: last?.title ?? 'Screen Recorder',
                mode: mode,
                canCompare: canCompare,
                onMode: (m) => setState(() => _mode = m),
                onHelp: () => _options.tourDone = false,
                onRecord: enabled ? widget.onStartRecording : null,
              ),
              const Divider(height: 1, color: Studio.divider),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Rail(
                      section: _section,
                      canCompare: canCompare,
                      hasSaved: last?.savedPath != null,
                      onRecord: enabled ? widget.onStartRecording : null,
                      onSection: _focusSection,
                      onCompare: () => setState(() => _mode = _ViewMode.compare),
                      onShowFolder: _showInFolder,
                    ),
                    const VerticalDivider(width: 1, color: Studio.divider),
                    Expanded(
                      child: _Stage(
                        controller: widget.controller,
                        recording: last,
                        mode: mode,
                        enabled: enabled,
                        onStartRecording: widget.onStartRecording,
                      ),
                    ),
                    if (wide) ...[
                      const VerticalDivider(width: 1, color: Studio.divider),
                      SizedBox(
                        width: 320,
                        child: _Inspector(
                          controller: widget.controller,
                          section: _section,
                          sectionKeys: _sectionKeys,
                          recording: last,
                          onShowFolder: _showInFolder,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1, color: Studio.divider),
              _StatusBar(controller: widget.controller),
            ],
          ),
          if (showTour)
            Positioned.fill(
              child: StudioTour(
                onFinish: () => _options.tourDone = true,
                onStep: (step) {
                  final section = switch (step.railIndex) {
                    1 => _Section.cursor,
                    2 => _Section.zoom,
                    _ => null,
                  };
                  if (section != null) _focusSection(section);
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Fallback when the window is tiny (e.g. while resizing to the chip).
class _CompactHome extends StatelessWidget {
  const _CompactHome({required this.controller, required this.onStartRecording});

  final RecordingController controller;
  final VoidCallback onStartRecording;

  @override
  Widget build(BuildContext context) {
    final enabled = controller.canBeginSelection && !controller.state.isBusy;
    return ColoredBox(
      color: Studio.chrome,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton(
              onPressed: enabled ? onStartRecording : null,
              style: FilledButton.styleFrom(backgroundColor: Studio.primary),
              child: const Text('Start Recording'),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.mode,
    required this.canCompare,
    required this.onMode,
    required this.onHelp,
    required this.onRecord,
  });

  final String title;
  final _ViewMode mode;
  final bool canCompare;
  final ValueChanged<_ViewMode> onMode;
  final VoidCallback onHelp;
  final VoidCallback? onRecord;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: HomeScreen.topBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            const Icon(Icons.crop_free_rounded, size: 22, color: Studio.ink),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: StudioText.title,
              ),
            ),
            Tooltip(
              message: canCompare
                  ? 'Original vs auto-zoomed'
                  : 'Record with auto-zoom on to compare',
              child: StudioSegmented<_ViewMode>(
                value: mode,
                onChanged: canCompare ? onMode : null,
                segments: const [
                  StudioSegment(_ViewMode.before, 'Before'),
                  StudioSegment(_ViewMode.compare, 'Compare'),
                  StudioSegment(_ViewMode.after, 'After'),
                ],
              ),
            ),
            const Expanded(child: SizedBox()),
            IconButton(
              tooltip: 'Show the tour',
              onPressed: onHelp,
              icon: const Icon(Icons.help_outline, size: 20, color: Studio.muted),
            ),
            const SizedBox(width: 8),
            StudioPrimaryButton(label: 'Record…', onPressed: onRecord),
          ],
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.section,
    required this.canCompare,
    required this.hasSaved,
    required this.onRecord,
    required this.onSection,
    required this.onCompare,
    required this.onShowFolder,
  });

  final _Section section;
  final bool canCompare;
  final bool hasSaved;
  final VoidCallback? onRecord;
  final ValueChanged<_Section> onSection;
  final VoidCallback onCompare;
  final VoidCallback onShowFolder;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: HomeScreen.railWidth,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: HomeScreen.railTopPadding),
        child: Column(
          children: [
            _RailItem(
              icon: Icons.radio_button_checked,
              label: 'Record',
              raised: true,
              onTap: onRecord,
            ),
            _RailItem(
              icon: Icons.ads_click,
              label: 'Cursor',
              selected: section == _Section.cursor,
              onTap: () => onSection(_Section.cursor),
            ),
            _RailItem(
              icon: Icons.zoom_in,
              label: 'Zoom',
              selected: section == _Section.zoom,
              onTap: () => onSection(_Section.zoom),
            ),
            _RailItem(
              icon: Icons.mic_none,
              label: 'Audio',
              selected: section == _Section.audio,
              onTap: () => onSection(_Section.audio),
            ),
            _RailItem(
              icon: Icons.compare,
              label: 'Compare',
              onTap: canCompare ? onCompare : null,
            ),
            _RailItem(
              icon: Icons.folder_open_outlined,
              label: 'Saved',
              onTap: hasSaved ? onShowFolder : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.raised = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final bool raised;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = enabled ? Studio.inkSoft : Studio.faint;
    return SizedBox(
      height: HomeScreen.railItemExtent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Material(
          color: raised
              ? Studio.surface
              : selected
                  ? const Color(0xFFE5E5E8)
                  : Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Studio.radius + 2),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Studio.radius + 2),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Studio.radius + 2),
                boxShadow: raised ? Studio.raised : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 21,
                    color: raised && enabled ? Studio.record : color,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? Studio.ink : color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Stage extends StatelessWidget {
  const _Stage({
    required this.controller,
    required this.recording,
    required this.mode,
    required this.enabled,
    required this.onStartRecording,
  });

  final RecordingController controller;
  final LastRecording? recording;
  final _ViewMode mode;
  final bool enabled;
  final VoidCallback onStartRecording;

  @override
  Widget build(BuildContext context) {
    final error = controller.errorMessage;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) ...[
            _Banner(text: error),
            const SizedBox(height: 10),
          ],
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Studio.well,
                borderRadius: BorderRadius.circular(Studio.radiusLg),
              ),
              padding: const EdgeInsets.all(18),
              child: recording == null
                  ? const _EmptyStage()
                  : _Preview(recording: recording!, mode: mode),
            ),
          ),
          const SizedBox(height: 12),
          _Transport(
            controller: controller,
            recording: recording,
            enabled: enabled,
            onStartRecording: onStartRecording,
          ),
          const SizedBox(height: 10),
          _Timeline(recording: recording),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFDECEA),
        borderRadius: BorderRadius.circular(Studio.radius),
        border: Border.all(color: const Color(0xFFF5C2BD)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: Studio.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 13, color: Color(0xFF8A1F17))),
          ),
        ],
      ),
    );
  }
}

class _EmptyStage extends StatelessWidget {
  const _EmptyStage();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 300,
                height: 180,
                child: CustomPaint(painter: EmptyStagePainter()),
              ),
              const SizedBox(height: 22),
              const Text(
                'Record any part of your screen',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'Drag a box around a window, a browser tab or the whole screen. '
                'When you stop, you choose how to export it.',
                textAlign: TextAlign.center,
                style: StudioText.label.copyWith(height: 1.45, color: Studio.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatefulWidget {
  const _Preview({required this.recording, required this.mode});

  final LastRecording recording;
  final _ViewMode mode;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  double _split = 0.5;

  @override
  Widget build(BuildContext context) {
    final rec = widget.recording;
    final after = rec.afterImage;
    if (after == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: Studio.muted),
            ),
            SizedBox(height: 12),
            Text('Preparing preview…', style: StudioText.caption),
          ],
        ),
      );
    }
    final aspect = rec.width > 0 && rec.height > 0 ? rec.width / rec.height : 16 / 9;
    final before = rec.beforeImage;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LayoutBuilder(
            builder: (context, box) {
              Widget image(File f) => Image.file(
                    f,
                    fit: BoxFit.cover,
                    width: box.maxWidth,
                    height: box.maxHeight,
                    gaplessPlayback: true,
                  );
              switch (widget.mode) {
                case _ViewMode.after:
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      image(after),
                      if (rec.hasComparison)
                        const Positioned(top: 10, right: 10, child: StudioBadge('After')),
                    ],
                  );
                case _ViewMode.before:
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      image(before ?? after),
                      const Positioned(top: 10, left: 10, child: StudioBadge('Before')),
                    ],
                  );
                case _ViewMode.compare:
                  final x = box.maxWidth * _split;
                  return GestureDetector(
                    onHorizontalDragUpdate: (d) => setState(() {
                      _split = (_split + d.delta.dx / box.maxWidth).clamp(0.05, 0.95);
                    }),
                    onTapDown: (d) => setState(() {
                      _split = (d.localPosition.dx / box.maxWidth).clamp(0.05, 0.95);
                    }),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          image(before ?? after),
                          ClipRect(
                            clipper: _RightOf(x),
                            child: image(after),
                          ),
                          Positioned(
                            left: x - 1,
                            top: 0,
                            bottom: 0,
                            child: Container(width: 2, color: Colors.white),
                          ),
                          Positioned(
                            left: x - 6,
                            top: box.maxHeight / 2 - 22,
                            child: Container(
                              width: 12,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: Studio.raised,
                              ),
                              child: const Center(
                                child: SizedBox(
                                  width: 2,
                                  height: 16,
                                  child: ColoredBox(color: Studio.faint),
                                ),
                              ),
                            ),
                          ),
                          const Positioned(top: 10, left: 10, child: StudioBadge('Before')),
                          const Positioned(top: 10, right: 10, child: StudioBadge('After')),
                        ],
                      ),
                    ),
                  );
              }
            },
          ),
        ),
      ),
    );
  }
}

class _RightOf extends CustomClipper<Rect> {
  const _RightOf(this.x);

  final double x;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(x, 0, size.width, size.height);

  @override
  bool shouldReclip(_RightOf oldClipper) => oldClipper.x != x;
}

String _clock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

class _Transport extends StatelessWidget {
  const _Transport({
    required this.controller,
    required this.recording,
    required this.enabled,
    required this.onStartRecording,
  });

  final RecordingController controller;
  final LastRecording? recording;
  final bool enabled;
  final VoidCallback onStartRecording;

  @override
  Widget build(BuildContext context) {
    final options = RecordingOptions.instance;
    final effects = RecordingOptions.effectsSupported;
    final length = recording?.duration;
    return SizedBox(
      height: 48,
      child: LayoutBuilder(builder: (context, box) {
      // Drop the least important pills first so nothing gets clipped.
      final showCursorPill = effects && box.maxWidth >= 720;
      final showZoomPill = effects && box.maxWidth >= 560;
      return Row(
        children: [
          FilledButton(
            onPressed: enabled ? onStartRecording : null,
            style: FilledButton.styleFrom(
              backgroundColor: Studio.primary,
              foregroundColor: Studio.onPrimary,
              disabledBackgroundColor: const Color(0xFF6B6B70),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 12, color: Studio.record),
                SizedBox(width: 8),
                Text('Start Recording'),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: _clock(controller.elapsed),
                  style: const TextStyle(fontWeight: FontWeight.w600, color: Studio.ink),
                ),
                if (length != null)
                  TextSpan(
                    text: ' / ${_clock(length)}',
                    style: const TextStyle(color: Studio.muted),
                  ),
              ],
            ),
            style: const TextStyle(
              fontSize: 14,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const Spacer(),
          if (showCursorPill) ...[
            StudioPill(
              icon: Icons.ads_click,
              label: options.cursorStyle.label,
              trailing: Icons.unfold_more,
              tooltip: 'Change cursor style',
              onTap: () {
                final values = CursorStyle.values;
                options.cursorStyle =
                    values[(options.cursorStyle.index + 1) % values.length];
              },
            ),
            const SizedBox(width: 8),
          ],
          if (showZoomPill) ...[
            StudioPill(
              icon: Icons.zoom_in,
              label: options.autoZoom
                  ? 'Auto-zoom ${options.zoomLevel.toStringAsFixed(1)}×'
                  : 'Auto-zoom off',
              trailing: Icons.unfold_more,
              tooltip: 'Turn auto-zoom on or off',
              onTap: () => options.autoZoom = !options.autoZoom,
            ),
            const SizedBox(width: 8),
          ],
          StudioPill(
            icon: controller.recordMicrophone ? Icons.mic : Icons.mic_off_outlined,
            label: controller.recordMicrophone ? 'Mic on' : 'Mic off',
            tooltip: 'Record your microphone',
            onTap: enabled
                ? () => controller.setRecordMicrophone(!controller.recordMicrophone)
                : null,
          ),
        ],
      );
      }),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.recording});

  final LastRecording? recording;

  @override
  Widget build(BuildContext context) {
    final strip = recording?.filmstrip;
    final seconds = recording?.duration.inSeconds ?? 0;
    return SizedBox(
      height: 76,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 18,
            child: Row(
              children: [
                const Text('0s', style: StudioText.tiny),
                const Spacer(),
                if (seconds > 1) Text('${seconds ~/ 2}s', style: StudioText.tiny),
                const Spacer(),
                if (seconds > 0) Text('${seconds}s', style: StudioText.tiny),
              ],
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2D),
                  border: Border.all(color: const Color(0xFF1A1A1C), width: 2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: strip != null
                    ? Image.file(strip, fit: BoxFit.fill, gaplessPlayback: true)
                    : Center(
                        child: Text(
                          recording == null
                              ? 'Your recording will show up here'
                              : 'Building timeline…',
                          style: StudioText.tiny.copyWith(color: const Color(0xFF9A9AA0)),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Inspector extends StatelessWidget {
  const _Inspector({
    required this.controller,
    required this.section,
    required this.sectionKeys,
    required this.recording,
    required this.onShowFolder,
  });

  final RecordingController controller;
  final _Section section;
  final Map<_Section, GlobalKey> sectionKeys;
  final LastRecording? recording;
  final VoidCallback onShowFolder;

  @override
  Widget build(BuildContext context) {
    final options = RecordingOptions.instance;
    final effects = RecordingOptions.effectsSupported;
    final editable = controller.canBeginSelection && !controller.state.isBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Cursor
                Text('Cursor', key: sectionKeys[_Section.cursor], style: StudioText.section),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.18,
                  children: [
                    for (final style in CursorStyle.values)
                      StudioTile(
                        label: style.label,
                        selected: options.cursorStyle == style,
                        preview: CustomPaint(painter: CursorStylePainter(style)),
                        onTap: effects && editable ? () => options.cursorStyle = style : null,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  effects ? options.cursorStyle.description : 'Cursor effects are available on Windows.',
                  style: StudioText.caption.copyWith(height: 1.45),
                ),
                const _InspectorDivider(),

                // Auto-zoom
                Row(
                  key: sectionKeys[_Section.zoom],
                  children: [
                    const Expanded(child: Text('Auto-zoom', style: StudioText.section)),
                    Switch(
                      value: effects && options.autoZoom,
                      onChanged: effects && editable ? (v) => options.autoZoom = v : null,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                StudioSliderRow(
                  label: 'Zoom level',
                  value: options.zoomLevel,
                  min: 1.2,
                  max: 3.0,
                  divisions: 18,
                  display: '${options.zoomLevel.toStringAsFixed(1)}×',
                  onChanged: effects && editable && options.autoZoom
                      ? (v) => options.zoomLevel = v
                      : null,
                ),
                StudioSliderRow(
                  label: 'Hold on click',
                  value: options.holdSeconds,
                  min: 1,
                  max: 5,
                  divisions: 16,
                  display: '${options.holdSeconds.toStringAsFixed(1)} s',
                  onChanged: effects && editable && options.autoZoom
                      ? (v) => options.holdSeconds = v
                      : null,
                ),
                StudioSliderRow(
                  label: 'Smoothness',
                  value: options.smoothness,
                  min: 1,
                  max: 10,
                  divisions: 9,
                  display: options.smoothness.round().toString(),
                  onChanged: effects && editable && options.autoZoom
                      ? (v) => options.smoothness = v
                      : null,
                ),
                const SizedBox(height: 4),
                Text(
                  effects
                      ? 'After you stop, the video zooms in where you click and follows your mouse, then eases back out.'
                      : 'Auto-zoom is available on Windows.',
                  style: StudioText.caption.copyWith(height: 1.45),
                ),
                const _InspectorDivider(),

                // Audio
                Text('Audio', key: sectionKeys[_Section.audio], style: StudioText.section),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Microphone', style: StudioText.body),
                          SizedBox(height: 2),
                          Text('Your voice, mixed into the video', style: StudioText.caption),
                        ],
                      ),
                    ),
                    Switch(
                      value: controller.recordMicrophone,
                      onChanged: editable ? controller.setRecordMicrophone : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (recording != null) ...[
          const Divider(height: 1, color: Studio.divider),
          _FileCard(recording: recording!, onShowFolder: onShowFolder),
        ],
      ],
    );
  }
}

class _InspectorDivider extends StatelessWidget {
  const _InspectorDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Divider(height: 1, color: Studio.divider),
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({required this.recording, required this.onShowFolder});

  final LastRecording recording;
  final VoidCallback onShowFolder;

  @override
  Widget build(BuildContext context) {
    final thumb = recording.afterImage;
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 88,
              height: 56,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  thumb != null
                      ? Image.file(thumb, fit: BoxFit.cover, gaplessPlayback: true)
                      : const ColoredBox(color: Studio.well),
                  if (recording.hasComparison)
                    const Positioned(
                      left: 4,
                      bottom: 4,
                      child: StudioBadge('After'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  recording.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(recording.summary, style: StudioText.caption),
                if (recording.savedPath != null)
                  GestureDetector(
                    onTap: onShowFolder,
                    child: const MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          'Show in folder',
                          style: TextStyle(
                            fontSize: 12,
                            color: Studio.ink,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.controller});

  final RecordingController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final dot = switch (state) {
      RecordingState.error => Studio.danger,
      RecordingState.recording => Studio.record,
      _ => Studio.ok,
    };
    return SizedBox(
      height: 36,
      child: LayoutBuilder(
        builder: (context, box) {
          final roomy = box.maxWidth > 1080;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                // Left group clips instead of overflowing in narrow windows.
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    child: Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 8),
                        Text('Status: ${state.label}', style: StudioText.tiny.copyWith(color: Studio.inkSoft)),
                        const _Dot(),
                        const Text('Runs on this PC', style: StudioText.tiny),
                        const _Dot(),
                        const Text('Bytes uploaded: ', style: StudioText.tiny),
                        const Text('0 B', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Studio.ink)),
                        if (roomy) ...[
                          const _Dot(),
                          Text(controller.backendName, style: StudioText.tiny),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const StudioKbd('Ctrl+Shift+R'),
                const SizedBox(width: 6),
                const Text('start', style: StudioText.tiny),
                if (box.maxWidth > 860) ...[
                  const SizedBox(width: 12),
                  const StudioKbd('Ctrl+Shift+S'),
                  const SizedBox(width: 6),
                  const Text('stop', style: StudioText.tiny),
                ],
                if (roomy) ...[
                  const SizedBox(width: 16),
                  const Text(
                    'Record only what you have the right to share.',
                    style: StudioText.tiny,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8),
      child: Text('·', style: StudioText.tiny),
    );
  }
}
