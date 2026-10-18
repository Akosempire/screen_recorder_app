import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../services/recording_library.dart';
import '../services/studio_save_service.dart';
import '../ui/studio_theme.dart';
import '../ui/studio_widgets.dart';

enum _ExportTab { settings, file, privacy }

/// "Export" sheet shown after a recording stops: Settings / File / Privacy.
class ExportDialog extends StatefulWidget {
  const ExportDialog({
    super.key,
    required this.recording,
    required this.settings,
    required this.onExport,
  });

  final LastRecording recording;
  final ExportSettings settings;

  /// Applies the settings and returns the destination path.
  final Future<String> Function(ExportSettings settings) onExport;

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  _ExportTab _tab = _ExportTab.settings;
  bool _busy = false;
  String? _error;
  late final TextEditingController _name =
      TextEditingController(text: widget.settings.fileName);

  ExportSettings get s => widget.settings;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final folder = await getDirectoryPath(
      initialDirectory: s.folder,
      confirmButtonText: 'Save here',
    );
    if (folder != null && mounted) {
      setState(() => s.folder = folder);
    }
  }

  Future<void> _save() async {
    s.fileName = _name.text;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final destination = await widget.onExport(s);
      if (mounted) Navigator.of(context).pop(destination);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not save with these settings. Try Original and Balanced.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Studio.theme(Theme.of(context)),
      child: Dialog(
        backgroundColor: Studio.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Studio.radiusLg + 4),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(30, 28, 30, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Export',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 18),
                Center(
                  child: StudioSegmented<_ExportTab>(
                    value: _tab,
                    onChanged: _busy ? null : (t) => setState(() => _tab = t),
                    segments: const [
                      StudioSegment(_ExportTab.settings, 'Settings'),
                      StudioSegment(_ExportTab.file, 'File'),
                      StudioSegment(_ExportTab.privacy, 'Privacy'),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                AnimatedSize(
                  duration: const Duration(milliseconds: 160),
                  alignment: Alignment.topCenter,
                  child: switch (_tab) {
                    _ExportTab.settings => _settingsTab(),
                    _ExportTab.file => _fileTab(),
                    _ExportTab.privacy => _privacyTab(),
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: Studio.danger, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 26),
                Row(
                  children: [
                    const Icon(Icons.lock_outline, size: 16, color: Studio.muted),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'On this PC, 0 bytes uploaded',
                        style: StudioText.caption,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    StudioSecondaryButton(
                      label: 'Cancel',
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 10),
                    StudioPrimaryButton(
                      label: _busy ? 'Saving…' : 'Save File',
                      busy: _busy,
                      onPressed: _save,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, Widget control, {String? caption, String? hint}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Studio.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: StudioText.body),
                if (hint != null) ...[
                  const SizedBox(height: 2),
                  Text(hint, style: StudioText.caption),
                ],
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              control,
              if (caption != null) ...[
                const SizedBox(height: 6),
                Text(caption, style: StudioText.tiny),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _dropdown<T>(T value, List<T> values, String Function(T) label,
      ValueChanged<T> onChanged) {
    return Container(
      width: 230,
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Studio.track,
        borderRadius: BorderRadius.circular(Studio.radius - 2),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          icon: const Icon(Icons.unfold_more, size: 16, color: Studio.muted),
          borderRadius: BorderRadius.circular(Studio.radius),
          dropdownColor: Studio.surface,
          style: StudioText.body,
          onChanged: _busy
              ? null
              : (v) {
                  if (v != null) onChanged(v);
                },
          items: [
            for (final v in values)
              DropdownMenuItem<T>(value: v, child: Text(label(v))),
          ],
        ),
      ),
    );
  }

  Widget _settingsTab() {
    final rec = widget.recording;
    final (outW, outH) = exportOutputSize(rec.width, rec.height, s.resolution);
    return Column(
      key: const ValueKey('settings'),
      children: [
        _row(
          'Format',
          const StudioSegmented<String>(
            value: 'mp4',
            onChanged: null,
            dense: true,
            segments: [StudioSegment('mp4', 'MP4', detail: 'Works everywhere')],
          ),
        ),
        _row(
          'Resolution',
          StudioSegmented<ExportResolution>(
            value: s.resolution,
            dense: true,
            onChanged: _busy ? null : (v) => setState(() => s.resolution = v),
            segments: [
              for (final r in ExportResolution.values)
                StudioSegment(
                  r,
                  r.label,
                  enabled: r.height == null || rec.height == 0 || rec.height > r.height!,
                ),
            ],
          ),
          caption: rec.width > 0 ? 'Output $outW×$outH' : null,
        ),
        _row(
          'Frame rate',
          _dropdown<ExportFrameRate>(
            s.frameRate,
            ExportFrameRate.values,
            (v) => v.label,
            (v) => setState(() => s.frameRate = v),
          ),
        ),
        _row(
          'Quality',
          _dropdown<ExportQuality>(
            s.quality,
            ExportQuality.values,
            (v) => v.label,
            (v) => setState(() => s.quality = v),
          ),
        ),
        _row(
          'Keep the sound',
          Switch(
            value: rec.hasAudio && s.keepSound,
            onChanged: rec.hasAudio && !_busy
                ? (v) => setState(() => s.keepSound = v)
                : null,
          ),
          hint: rec.hasAudio
              ? 'Microphone audio recorded with the video'
              : 'This recording has no sound',
        ),
      ],
    );
  }

  Widget _fileTab() {
    return Column(
      key: const ValueKey('file'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(
          'File name',
          SizedBox(
            width: 300,
            child: TextField(
              controller: _name,
              enabled: !_busy,
              style: StudioText.body,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Studio.track,
                suffixText: '.mp4',
                suffixStyle: StudioText.caption,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Studio.radius - 2),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        _row(
          'Folder',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 210),
                child: Text(
                  s.folder,
                  overflow: TextOverflow.ellipsis,
                  style: StudioText.caption,
                ),
              ),
              const SizedBox(width: 10),
              StudioSecondaryButton(
                label: 'Change…',
                icon: Icons.folder_open_outlined,
                onPressed: _busy ? null : _pickFolder,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _privacyTab() {
    Widget line(IconData icon, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: Studio.inkSoft),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: StudioText.body)),
            ],
          ),
        );
    return Column(
      key: const ValueKey('privacy'),
      children: [
        line(Icons.computer_outlined,
            'Recording, auto-zoom and export all run on this PC with the bundled FFmpeg.'),
        line(Icons.cloud_off_outlined,
            'Nothing is uploaded. No account, no analytics.'),
        line(Icons.folder_outlined,
            'The video is only written to the folder you choose.'),
      ],
    );
  }
}
