import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/recording_background.dart';
import '../services/recording_edit.dart';
import '../services/recording_library.dart';
import '../services/recording_options.dart';
import '../ui/background_widgets.dart';
import '../ui/studio_theme.dart';
import '../ui/studio_widgets.dart';

/// Shown right after a recording stops: trim the ends, cut out sections,
/// pick a background, then export. Nothing changes until export.
class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    required this.recording,
    required this.onExport,
    this.initialEdit,
  });

  final LastRecording recording;

  /// Opens the Export dialog with the kept segments (null = whole video) and
  /// returns the saved path, or null if the dialog was cancelled.
  final Future<String?> Function(List<EditRange>? segments) onExport;

  /// For demos and tests.
  final RecordingEdit? initialEdit;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final RecordingEdit _edit = widget.initialEdit ??
      RecordingEdit(widget.recording.duration.inMilliseconds / 1000.0);
  File? _frame;
  double _framedAt = -1;
  Timer? _debounce;
  int _request = 0;
  bool _exporting = false;

  LastRecording get _rec => widget.recording;

  @override
  void initState() {
    super.initState();
    if (widget.initialEdit == null) {
      _edit.playhead = (_rec.focusSeconds ?? _edit.duration * 0.35).clamp(0.0, _edit.duration).toDouble();
    }
    _edit.addListener(_onEdit);
    _loadFrame();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _edit.removeListener(_onEdit);
    if (widget.initialEdit == null) _edit.dispose();
    super.dispose();
  }

  void _onEdit() {
    if ((_edit.playhead - _framedAt).abs() >= 0.05) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 90), _loadFrame);
    }
  }

  Future<void> _loadFrame() async {
    final id = ++_request;
    final at = _edit.playhead;
    final file = await RecordingLibrary.instance.frameAt(_rec, at);
    if (!mounted || id != _request) return;
    setState(() {
      _framedAt = at;
      if (file != null) _frame = file;
    });
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final destination = await widget.onExport(_edit.exportSegments);
      if (destination != null && mounted) Navigator.of(context).pop(destination);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Studio.theme(Theme.of(context)),
      child: Scaffold(
        backgroundColor: Studio.chrome,
        body: SafeArea(
          child: ListenableBuilder(
            listenable: Listenable.merge([_edit, RecordingOptions.instance, RecordingLibrary.instance]),
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                const Divider(height: 1, color: Studio.divider),
                Expanded(child: _preview()),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                  child: _BackgroundStrip(spec: RecordingOptions.instance.background),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _timeLabels(),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _EditTimeline(edit: _edit, strip: _rec.filmstrip),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
                  child: _toolbar(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            const Icon(Icons.content_cut, size: 20, color: Studio.ink),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Edit your recording', style: StudioText.title, overflow: TextOverflow.ellipsis),
                  SizedBox(height: 2),
                  Text(
                    'Trim the ends, cut out mistakes and pick a background. Your recording is only changed when you export.',
                    style: StudioText.caption,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            StudioSecondaryButton(
              label: 'Close',
              onPressed: _exporting ? null : () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 10),
            StudioPrimaryButton(
              label: 'Export…',
              busy: _exporting,
              onPressed: _exporting || _edit.keptDuration <= 0 ? null : _export,
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview() {
    final aspect = _rec.width > 0 && _rec.height > 0 ? _rec.width / _rec.height : 16 / 9;
    final image = _frame ?? _rec.afterImage;
    final inCut = !_edit.kept.any((r) => _edit.playhead >= r.start && _edit.playhead <= r.end);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Container(
        decoration: BoxDecoration(color: Studio.well, borderRadius: BorderRadius.circular(Studio.radiusLg)),
        padding: const EdgeInsets.all(16),
        child: Center(
          child: AspectRatio(
            aspectRatio: aspect,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RecordingOnBackground(
                    spec: RecordingOptions.instance.background,
                    child: image == null
                        ? const ColoredBox(
                            color: Color(0xFF2A2A2D),
                            child: Center(child: Text('Preparing preview…', style: TextStyle(color: Color(0xFF9A9AA0)))),
                          )
                        : Image.file(image, fit: BoxFit.cover, gaplessPlayback: true),
                  ),
                  if (inCut)
                    const ColoredBox(
                      color: Color(0x99000000),
                      child: Center(
                        child: StudioBadge('Cut: this part won’t be in the export'),
                      ),
                    ),
                  Positioned(left: 10, bottom: 10, child: StudioBadge(_clock(_edit.playhead, tenths: true))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _timeLabels() {
    final d = _edit.duration;
    return SizedBox(
      height: 18,
      child: Row(
        children: [
          Text(_clock(0), style: StudioText.tiny),
          const Spacer(),
          Text(_clock(d / 2), style: StudioText.tiny),
          const Spacer(),
          Text(_clock(d), style: StudioText.tiny),
        ],
      ),
    );
  }

  Widget _toolbar() {
    final kept = _edit.keptDuration;
    return Row(
      children: [
        StudioPill(
          icon: Icons.content_cut,
          label: 'Add cut',
          tooltip: 'Cut out a section at the playhead. Drag its edges to resize it.',
          onTap: () => _edit.addCutAtPlayhead(),
        ),
        const SizedBox(width: 8),
        StudioPill(
          icon: Icons.undo,
          label: 'Reset',
          tooltip: 'Undo all trims and cuts',
          onTap: _edit.isEdited ? _edit.reset : null,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            'Drag the yellow handles to trim the start or end. Click the timeline to preview any moment.',
            style: StudioText.caption,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        Text.rich(
          TextSpan(children: [
            const TextSpan(text: 'Keeps ', style: TextStyle(color: Studio.muted)),
            TextSpan(text: _clock(kept), style: const TextStyle(fontWeight: FontWeight.w600, color: Studio.ink)),
            TextSpan(text: ' of ${_clock(_edit.duration)}', style: const TextStyle(color: Studio.muted)),
          ]),
          style: const TextStyle(fontSize: 13.5, fontFeatures: [FontFeature.tabularFigures()]),
        ),
      ],
    );
  }
}

String _clock(double seconds, {bool tenths = false}) {
  final s = math.max(0.0, seconds);
  final m = s ~/ 60;
  final rest = s - m * 60;
  final secs = tenths ? rest.toStringAsFixed(1).padLeft(4, '0') : rest.floor().toString().padLeft(2, '0');
  return '$m:$secs';
}

/// Quick background choice under the preview (full controls are in the
/// Backdrop panel).
class _BackgroundStrip extends StatelessWidget {
  const _BackgroundStrip({required this.spec});

  final BackgroundSpec spec;

  @override
  Widget build(BuildContext context) {
    final options = RecordingOptions.instance;
    final image = spec.imagePath;
    final hasImage = image != null && File(image).existsSync();
    Widget chip({required String tooltip, required bool selected, required Widget child, required VoidCallback onTap}) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Tooltip(
          message: tooltip,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 40,
                height: 26,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: selected ? Studio.primary : Studio.border, width: selected ? 2 : 1),
                ),
                child: ClipRRect(borderRadius: BorderRadius.circular(5), child: child),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 30,
      child: Row(
        children: [
          const Text('Background', style: StudioText.label),
          const SizedBox(width: 12),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                chip(
                  tooltip: 'No background',
                  selected: spec.kind == BackgroundKind.none,
                  onTap: () => options.setBackgroundKind(BackgroundKind.none),
                  child: const ColoredBox(
                    color: Studio.surface,
                    child: Center(child: Icon(Icons.block, size: 14, color: Studio.muted)),
                  ),
                ),
                for (final preset in BackgroundPreset.values)
                  chip(
                    tooltip: preset.label,
                    selected: spec.kind == BackgroundKind.preset && spec.preset == preset,
                    onTap: () => options.setBackgroundPreset(preset),
                    child: CustomPaint(painter: BackgroundPresetPainter(preset)),
                  ),
                if (hasImage)
                  chip(
                    tooltip: 'Your image',
                    selected: spec.kind == BackgroundKind.image,
                    onTap: () => options.setBackgroundImage(image!),
                    child: Image.file(File(image!), fit: BoxFit.cover),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Filmstrip with trim handles, cut sections and a playhead.
class _EditTimeline extends StatelessWidget {
  const _EditTimeline({required this.edit, required this.strip});

  final RecordingEdit edit;
  final File? strip;

  static const double height = 76;
  static const double inset = 8; // room above/below the strip for handles

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = math.max(1.0, box.maxWidth);
          final d = edit.duration > 0 ? edit.duration : 1.0;
          double x(double t) => t / d * w;
          double dt(double dx) => dx / w * d;
          double at(double px) => (px / w * d).clamp(0.0, d).toDouble();

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Filmstrip; click or drag to move the playhead.
              Positioned.fill(
                top: inset,
                bottom: inset,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (e) => edit.playhead = at(e.localPosition.dx),
                  onHorizontalDragUpdate: (e) => edit.playhead = at(e.localPosition.dx),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      color: const Color(0xFF2A2A2D),
                      child: strip != null
                          ? Image.file(strip!, fit: BoxFit.fill, gaplessPlayback: true)
                          : const Center(
                              child: Text('Building timeline…', style: TextStyle(fontSize: 11.5, color: Color(0xFF9A9AA0))),
                            ),
                    ),
                  ),
                ),
              ),
              // Trimmed-away ends.
              Positioned(
                left: 0,
                width: x(edit.trimStart),
                top: inset,
                bottom: inset,
                child: const IgnorePointer(child: _Dim()),
              ),
              Positioned(
                left: x(edit.trimEnd),
                right: 0,
                top: inset,
                bottom: inset,
                child: const IgnorePointer(child: _Dim()),
              ),
              // Cuts.
              for (var i = 0; i < edit.cuts.length; i++)
                Positioned(
                  left: x(edit.cuts[i].start),
                  width: math.max(28.0, x(edit.cuts[i].end) - x(edit.cuts[i].start)),
                  top: inset,
                  bottom: inset,
                  child: _CutBox(
                    onMove: (dx) {
                      final c = edit.cuts[i];
                      final shift = dt(dx).clamp(-c.start, edit.duration - c.end).toDouble();
                      edit.setCut(i, c.start + shift, c.end + shift);
                      edit.playhead = c.start + shift;
                    },
                    onStart: (dx) {
                      final c = edit.cuts[i];
                      final s = math.min(c.start + dt(dx), c.end - RecordingEdit.minPiece);
                      edit.setCut(i, s, c.end);
                      edit.playhead = s;
                    },
                    onEnd: (dx) {
                      final c = edit.cuts[i];
                      final e = math.max(c.end + dt(dx), c.start + RecordingEdit.minPiece);
                      edit.setCut(i, c.start, e);
                      edit.playhead = e;
                    },
                    onRemove: () => edit.removeCut(i),
                  ),
                ),
              // Trim handles.
              Positioned(
                left: x(edit.trimStart) - 7,
                top: 2,
                bottom: 2,
                width: 14,
                child: _TrimHandle(
                  tooltip: 'Start',
                  onDrag: (dx) {
                    edit.trimStart = edit.trimStart + dt(dx);
                    edit.playhead = edit.trimStart;
                  },
                ),
              ),
              Positioned(
                left: x(edit.trimEnd) - 7,
                top: 2,
                bottom: 2,
                width: 14,
                child: _TrimHandle(
                  tooltip: 'End',
                  onDrag: (dx) {
                    edit.trimEnd = edit.trimEnd + dt(dx);
                    edit.playhead = edit.trimEnd;
                  },
                ),
              ),
              // Playhead.
              Positioned(
                left: x(edit.playhead) - 1,
                top: 0,
                bottom: 0,
                width: 2,
                child: const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 3)],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Dim extends StatelessWidget {
  const _Dim();

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Color(0xB3141416));
}

class _TrimHandle extends StatelessWidget {
  const _TrimHandle({required this.tooltip, required this.onDrag});

  final String tooltip;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Drag to trim the $tooltip',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
          child: Center(
            child: Container(
              width: 10,
              decoration: BoxDecoration(
                color: Studio.highlight,
                borderRadius: BorderRadius.circular(4),
                boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4)],
              ),
              child: const Center(
                child: SizedBox(width: 2, height: 16, child: ColoredBox(color: Color(0x99000000))),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CutBox extends StatelessWidget {
  const _CutBox({required this.onMove, required this.onStart, required this.onEnd, required this.onRemove});

  final ValueChanged<double> onMove;
  final ValueChanged<double> onStart;
  final ValueChanged<double> onEnd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    Widget edge(ValueChanged<double> onDrag) => MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
            child: const SizedBox(width: 7, child: ColoredBox(color: Studio.danger)),
          ),
        );
    return Stack(
      fit: StackFit.expand,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) => onMove(d.delta.dx),
            child: ColoredBox(
              color: const Color(0x99D93A2F),
              child: Center(
                child: Tooltip(
                  message: 'Remove this cut',
                  child: InkWell(
                    onTap: onRemove,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Studio.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: Studio.danger),
                      ),
                      child: const Icon(Icons.close, size: 12, color: Studio.danger),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Align(alignment: Alignment.centerLeft, child: edge(onStart)),
        Align(alignment: Alignment.centerRight, child: edge(onEnd)),
      ],
    );
  }
}
