import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/pro_service.dart';
import '../services/recording_background.dart';
import '../services/recording_edit.dart';
import '../services/recording_library.dart';
import '../services/recording_options.dart';
import '../ui/background_widgets.dart';
import '../ui/studio_theme.dart';
import '../ui/studio_widgets.dart';
import 'upgrade_dialog.dart';

/// Shown right after a recording stops: trim the ends, cut out sections,
/// pick a background, then export. Nothing changes until export.
class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    required this.recording,
    required this.onExport,
    this.initialEdit,
    this.playback = true,
  });

  final LastRecording recording;

  /// Opens the Export dialog with the kept segments (null = whole video) and
  /// returns the saved path, or null if the dialog was cancelled.
  final Future<String?> Function(List<EditRange>? segments) onExport;

  /// For demos and tests.
  final RecordingEdit? initialEdit;

  /// Play the video (with sound). Off in tests, which have no media engine.
  final bool playback;

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

  // Playback (media_kit). Play follows the edits: it skips cuts and stops at
  // the end trim, so you watch exactly what will be exported.
  Player? _player;
  VideoController? _video;
  final List<StreamSubscription<Object?>> _subs = [];
  bool _playing = false;
  bool _videoReady = false;
  bool _fromPlayer = false;
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  LastRecording get _rec => widget.recording;

  @override
  void initState() {
    super.initState();
    if (widget.initialEdit == null) {
      _edit.playhead = (_rec.focusSeconds ?? _edit.duration * 0.35).clamp(0.0, _edit.duration).toDouble();
    }
    _edit.addListener(_onEdit);
    if (widget.playback) _startPlayer();
    _loadFrame();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _player?.dispose();
    _edit.removeListener(_onEdit);
    if (widget.initialEdit == null) _edit.dispose();
    super.dispose();
  }

  static Duration _at(double seconds) => Duration(milliseconds: (seconds * 1000).round());

  void _startPlayer() {
    try {
      final player = Player();
      _player = player;
      _video = VideoController(player);
      _subs
        ..add(player.stream.position.listen(_onPosition))
        ..add(player.stream.playing.listen((playing) {
          if (mounted) setState(() => _playing = playing);
        }))
        ..add(player.stream.completed.listen((done) {
          if (done && _playing) player.pause();
        }))
        ..add(player.stream.width.listen((width) {
          if (width != null && width > 0 && mounted && !_videoReady) {
            setState(() => _videoReady = true);
          }
        }));
      unawaited(
        player.open(Media(_rec.finalPath), play: false).then((_) => player.seek(_at(_edit.playhead))),
      );
    } catch (error) {
      _player = null;
      _video = null;
    }
  }

  /// While playing: follow the video, skip cuts, stop after the last kept part.
  void _onPosition(Duration position) {
    final player = _player;
    if (player == null || !_playing) return;
    final t = position.inMilliseconds / 1000.0;
    final next = nextPlayableTime(_edit.kept, t);
    if (next == null) {
      player.pause();
      return;
    }
    if (next - t > 0.05) player.seek(_at(next));
    _fromPlayer = true;
    _edit.playhead = next;
    _fromPlayer = false;
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null) return;
    if (_playing) {
      await player.pause();
      return;
    }
    final kept = _edit.kept;
    if (kept.isEmpty) return;
    final start = nextPlayableTime(kept, _edit.playhead) ?? kept.first.start;
    await player.seek(_at(start));
    await player.play();
  }

  void _onEdit() {
    if (_fromPlayer) return;
    final player = _player;
    if (player != null) {
      // The playhead was moved by hand: show that moment (seeks are throttled).
      final now = DateTime.now();
      _debounce?.cancel();
      if (now.difference(_lastSeek).inMilliseconds >= 50) {
        _lastSeek = now;
        player.seek(_at(_edit.playhead));
      } else {
        _debounce = Timer(const Duration(milliseconds: 60), () => player.seek(_at(_edit.playhead)));
      }
    }
    if (!_videoReady && (_edit.playhead - _framedAt).abs() >= 0.05) {
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

  /// Closes the player so the video file is not in use (Windows can't
  /// replace a file that is open).
  Future<void> _releasePlayer() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    final player = _player;
    _player = null;
    _video = null;
    _videoReady = false;
    _playing = false;
    await player?.dispose();
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    await _releasePlayer();
    String? destination;
    try {
      destination = await widget.onExport(_edit.exportSegments);
      if (destination != null && mounted) Navigator.of(context).pop(destination);
    } finally {
      if (mounted) {
        if (destination == null && widget.playback) _startPlayer();
        setState(() => _exporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Studio.theme(Theme.of(context)),
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.space): _togglePlay},
        child: Focus(
          autofocus: true,
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
                const _LimitBanner(),
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
    final video = _video;
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
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (image == null)
                          const ColoredBox(
                            color: Color(0xFF2A2A2D),
                            child: Center(child: Text('Preparing preview…', style: TextStyle(color: Color(0xFF9A9AA0)))),
                          )
                        else
                          Image.file(image, fit: BoxFit.cover, gaplessPlayback: true),
                        if (video != null && _videoReady)
                          Video(
                            controller: video,
                            controls: NoVideoControls,
                            fit: BoxFit.cover,
                            fill: Colors.transparent,
                          ),
                      ],
                    ),
                  ),
                  if (inCut && !_playing)
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
        if (_player != null) ...[
          StudioPill(
            icon: _playing ? Icons.pause : Icons.play_arrow,
            label: _playing ? 'Pause' : 'Play',
            tooltip: 'Play the edited video, skipping cuts (Space)',
            onTap: _togglePlay,
          ),
          const SizedBox(width: 8),
        ],
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
            'Drag the yellow handles to trim. Click the timeline to jump anywhere. Play skips the cuts.',
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

/// Shown when a free recording was stopped by the time limit.
class _LimitBanner extends StatelessWidget {
  const _LimitBanner();

  @override
  Widget build(BuildContext context) {
    final pro = ProService.instance;
    return ListenableBuilder(
      listenable: pro,
      builder: (context, _) {
        if (!pro.stoppedAtLimit || pro.isPro) return const SizedBox.shrink();
        return Container(
          color: const Color(0xFFFFF6DB),
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
          child: Row(
            children: [
              const Icon(Icons.timer_outlined, size: 18, color: Color(0xFF8A6100)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Trial recordings stop at ${pro.freeLimit.inMinutes} minutes, so this one stopped there. '
                  'It\'s saved: edit and export it as usual. Go Pro to record as long as you like.',
                  style: StudioText.body,
                ),
              ),
              const SizedBox(width: 10),
              StudioPrimaryButton(label: 'Upgrade', onPressed: () => showUpgradeDialog(context)),
            ],
          ),
        );
      },
    );
  }
}
