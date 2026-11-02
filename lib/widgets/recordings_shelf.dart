import 'dart:io';

import 'package:flutter/material.dart';

import '../services/app_folders.dart';
import '../services/draft_store.dart';
import '../ui/studio_theme.dart';

/// "Recordings" under the home stage: every recording, saved automatically.
/// Click one to play, edit and export it; the menu shows it in its folder or
/// deletes it.
class RecordingsShelf extends StatelessWidget {
  const RecordingsShelf({
    super.key,
    required this.store,
    required this.onOpen,
    this.enabled = true,
    this.currentId,
  });

  final DraftStore store;
  final ValueChanged<Draft> onOpen;
  final bool enabled;

  /// The recording shown on the stage (highlighted).
  final String? currentId;

  static const double height = 96;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final drafts = store.drafts;
        final waiting = store.unexportedCount;
        return SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 20,
                child: Row(
                  children: [
                    const Text('Recordings', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Studio.ink)),
                    const SizedBox(width: 8),
                    if (drafts.isNotEmpty)
                      Text(
                        waiting == 0 ? '${drafts.length} · all exported' : '${drafts.length} · $waiting not exported yet',
                        style: StudioText.tiny,
                      ),
                    const Spacer(),
                    if (drafts.isNotEmpty)
                      const Flexible(
                        child: Text(
                          'Saved automatically. Click one to play, edit or export.',
                          style: StudioText.tiny,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: drafts.isEmpty
                    ? Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A2D),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: const Text(
                          'Your recordings will show up here. Each one is saved as a draft, so you can edit and export it later.',
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                          style: TextStyle(fontSize: 12.5, color: Color(0xFF9A9AA0)),
                        ),
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: drafts.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, i) => _DraftCard(
                          draft: drafts[i],
                          selected: drafts[i].id == currentId,
                          enabled: enabled,
                          onOpen: () => onOpen(drafts[i]),
                          onDelete: () => _confirmDelete(context, drafts[i]),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, Draft draft) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this recording?'),
        content: Text(
          draft.isExported
              ? 'It will be removed from Recordings. Videos you already exported are kept.'
              : 'It hasn’t been exported yet, so it will be gone for good.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Studio.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await store.delete(draft.id);
  }
}

enum _CardAction { open, showExport, showFolder, delete }

class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.draft,
    required this.selected,
    required this.enabled,
    required this.onOpen,
    required this.onDelete,
  });

  final Draft draft;
  final bool selected;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final exported = draft.isExported;
    return Tooltip(
      message: enabled ? 'Play, edit or export' : 'Finish the current recording first',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? onOpen : null,
          child: Container(
            width: 236,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: Studio.surface,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: selected ? Studio.primary : Studio.border, width: selected ? 2 : 1),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: SizedBox(
                    width: 104,
                    height: 58,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (draft.hasThumb)
                          Image.file(File(draft.thumbPath), fit: BoxFit.cover, gaplessPlayback: true)
                        else
                          const ColoredBox(color: Color(0xFF2A2A2D)),
                        const Center(
                          child: Icon(Icons.play_circle_fill_rounded, size: 24, color: Color(0xDDFFFFFF)),
                        ),
                        Positioned(
                          right: 3,
                          bottom: 3,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(3)),
                            child: Text(draft.lengthLabel, style: const TextStyle(fontSize: 10, color: Colors.white)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        draftDateLabel(draft.createdAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Studio.ink),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: exported ? const Color(0xFFE4F4EA) : const Color(0xFFFFF4D6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          exported ? 'Exported' : 'Draft',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: exported ? const Color(0xFF1E7A3C) : const Color(0xFF8A5A00),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 26,
                  child: PopupMenuButton<_CardAction>(
                    tooltip: 'More',
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: const Icon(Icons.more_vert, size: 18, color: Studio.muted),
                    enabled: enabled,
                    onSelected: (a) {
                      switch (a) {
                        case _CardAction.open:
                          onOpen();
                        case _CardAction.showExport:
                          revealInFileManager(draft.exportedTo.last);
                        case _CardAction.showFolder:
                          revealInFileManager(draft.videoPath);
                        case _CardAction.delete:
                          onDelete();
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: _CardAction.open, child: Text('Play, edit or export')),
                      if (exported && File(draft.exportedTo.last).existsSync())
                        const PopupMenuItem(value: _CardAction.showExport, child: Text('Show exported video')),
                      const PopupMenuItem(value: _CardAction.showFolder, child: Text('Show recording file')),
                      const PopupMenuItem(value: _CardAction.delete, child: Text('Delete')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
