import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_folders.dart';
import 'app_logger.dart';
import 'ffmpeg_binary.dart';
import 'ffmpeg_process_manager.dart';
import 'recording_edit.dart';

/// One recording kept by the app: a draft until it's exported, and still
/// there afterwards so it can be edited and exported again.
///
/// Stored as a folder: `video.mp4` (what gets exported), optionally
/// `original.mp4` (before auto-zoom), `thumb.jpg` and `draft.json`.
class Draft {
  Draft({
    required this.id,
    required this.folder,
    required this.createdAt,
    required this.width,
    required this.height,
    required this.duration,
    required this.hasAudio,
    this.focusSeconds,
    this.trimStart,
    this.trimEnd,
    this.cuts = const [],
    this.exportedTo = const [],
  });

  final String id;
  final String folder;
  final DateTime createdAt;
  final int width;
  final int height;
  final Duration duration;
  final bool hasAudio;
  final double? focusSeconds;

  /// Edits saved with the draft (null / empty: none).
  double? trimStart;
  double? trimEnd;
  List<EditRange> cuts;

  /// Files this recording was exported to, newest last.
  List<String> exportedTo;

  String get videoPath => p.join(folder, 'video.mp4');
  String get originalPath => p.join(folder, 'original.mp4');
  String get thumbPath => p.join(folder, 'thumb.jpg');

  bool get hasOriginal => File(originalPath).existsSync();
  bool get hasThumb => File(thumbPath).existsSync();
  bool get isExported => exportedTo.isNotEmpty;
  bool get hasEdits => (trimStart ?? 0) > 0.01 || (trimEnd != null && trimEnd! < duration.inMilliseconds / 1000 - 0.01) || cuts.isNotEmpty;

  /// "Recording · 2 Nov, 10:42".
  String get title => 'Recording · ${draftDateLabel(createdAt)}';

  String get lengthLabel {
    final s = duration.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Map<String, Object?> toJson() => {
        'version': 1,
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'width': width,
        'height': height,
        'durationMs': duration.inMilliseconds,
        'hasAudio': hasAudio,
        if (focusSeconds != null) 'focusSeconds': focusSeconds,
        if (trimStart != null) 'trimStart': trimStart,
        if (trimEnd != null) 'trimEnd': trimEnd,
        'cuts': [for (final c in cuts) [c.start, c.end]],
        'exportedTo': exportedTo,
      };

  static Draft? fromJson(String folder, Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final created = DateTime.tryParse('${json['createdAt']}');
    final ms = json['durationMs'];
    if (id is! String || created == null || ms is! int) return null;
    double? num_(Object? v) => v is num ? v.toDouble() : null;
    final cuts = <EditRange>[];
    final rawCuts = json['cuts'];
    if (rawCuts is List) {
      for (final c in rawCuts) {
        if (c is List && c.length == 2 && c[0] is num && c[1] is num) {
          cuts.add(EditRange((c[0] as num).toDouble(), (c[1] as num).toDouble()));
        }
      }
    }
    final exported = json['exportedTo'];
    return Draft(
      id: id,
      folder: folder,
      createdAt: created,
      width: json['width'] is int ? json['width'] as int : 0,
      height: json['height'] is int ? json['height'] as int : 0,
      duration: Duration(milliseconds: ms),
      hasAudio: json['hasAudio'] == true,
      focusSeconds: num_(json['focusSeconds']),
      trimStart: num_(json['trimStart']),
      trimEnd: num_(json['trimEnd']),
      cuts: cuts,
      exportedTo: exported is List ? exported.whereType<String>().toList() : <String>[],
    );
  }
}

String draftDateLabel(DateTime t, {DateTime? now}) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final n = now ?? DateTime.now();
  final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  if (day == today) return 'Today, $time';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday, $time';
  return '${t.day} ${months[t.month - 1]}${t.year != n.year ? ' ${t.year}' : ''}, $time';
}

/// Every recording, kept until the user deletes it. Recordings are moved here
/// from the temporary folder as soon as they stop, so recording again (or
/// closing the editor, or the app) never loses one.
class DraftStore extends ChangeNotifier {
  DraftStore({Directory? root, ProcessRunner? runner})
      : _root = root,
        runner = runner ?? const ProcessRunner();

  static final DraftStore instance = DraftStore();

  Directory? _root;
  ProcessRunner runner;
  List<Draft> _drafts = [];
  bool _loaded = false;

  /// Where drafts live (in the app's settings folder).
  Directory? get root {
    if (_root != null) return _root;
    final settings = appSettingsFolder();
    return settings == null ? null : Directory(p.join(settings.path, 'recordings'));
  }

  /// Newest first.
  List<Draft> get drafts => List.unmodifiable(_drafts);
  bool get loaded => _loaded;
  int get unexportedCount => _drafts.where((d) => !d.isExported).length;

  Draft? byId(String? id) {
    if (id == null) return null;
    for (final d in _drafts) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<void> load() async {
    final dir = root;
    final out = <Draft>[];
    if (dir != null && await dir.exists()) {
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        try {
          final meta = File(p.join(entry.path, 'draft.json'));
          if (!await meta.exists()) continue;
          final draft = Draft.fromJson(entry.path, jsonDecode(await meta.readAsString()));
          if (draft != null && await File(draft.videoPath).exists()) out.add(draft);
        } catch (error) {
          AppLogger.debug('Skipping unreadable draft ${entry.path}: $error');
        }
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _drafts = out;
    _loaded = true;
    notifyListeners();
  }

  /// Moves a just-finished recording (and its pre-zoom original) into the
  /// drafts folder. If moving fails the files are copied; if there's no
  /// drafts folder at all, returns null and the recording stays where it is.
  Future<Draft?> createFrom({
    required String video,
    String? original,
    required int width,
    required int height,
    required Duration duration,
    required bool hasAudio,
    double? focusSeconds,
    DateTime? now,
  }) async {
    final dir = root;
    if (dir == null) return null;
    final created = now ?? DateTime.now();
    final id = '${created.millisecondsSinceEpoch}';
    final folder = Directory(p.join(dir.path, id));
    try {
      await folder.create(recursive: true);
      final draft = Draft(
        id: id,
        folder: folder.path,
        createdAt: created,
        width: width,
        height: height,
        duration: duration,
        hasAudio: hasAudio,
        focusSeconds: focusSeconds,
      );
      await _move(video, draft.videoPath);
      if (original != null && original != video && await File(original).exists()) {
        try {
          await _move(original, draft.originalPath);
        } catch (error) {
          AppLogger.debug('Could not keep the pre-zoom original: $error');
        }
      }
      await _write(draft);
      _drafts = [draft, ..._drafts.where((d) => d.id != id)];
      notifyListeners();
      AppLogger.info('Saved recording as draft ${draft.folder}');
      await _thumbnail(draft);
      return draft;
    } catch (error, stack) {
      AppLogger.error('Could not save the recording as a draft', error, stack);
      try {
        // Undo a half-made draft, but only if the video is still where it was.
        if (await File(video).exists()) await folder.delete(recursive: true);
      } catch (_) {}
      return null;
    }
  }

  Future<void> saveEdits(String id, {double? trimStart, double? trimEnd, List<EditRange> cuts = const []}) async {
    final d = byId(id);
    if (d == null) return;
    d
      ..trimStart = trimStart
      ..trimEnd = trimEnd
      ..cuts = List.of(cuts);
    await _write(d);
    notifyListeners();
  }

  Future<void> markExported(String id, String path) async {
    final d = byId(id);
    if (d == null) return;
    d.exportedTo = [...d.exportedTo.where((e) => e != path), path];
    await _write(d);
    notifyListeners();
  }

  /// Deletes the draft's folder (exported copies are left alone).
  Future<void> delete(String id) async {
    final d = byId(id);
    if (d == null) return;
    try {
      await Directory(d.folder).delete(recursive: true);
    } catch (error) {
      AppLogger.warn('Could not delete draft ${d.folder}: $error');
    }
    _drafts = _drafts.where((x) => x.id != id).toList();
    notifyListeners();
  }

  Future<void> _write(Draft d) async {
    final file = File(p.join(d.folder, 'draft.json'));
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(d.toJson()));
    await tmp.rename(file.path);
  }

  static Future<void> _move(String from, String to) async {
    try {
      await File(from).rename(to);
    } on FileSystemException {
      // Different drive (e.g. temp on C:, settings elsewhere): copy, then remove.
      await File(from).copy(to);
      try {
        await File(from).delete();
      } catch (_) {}
    }
  }

  Future<void> _thumbnail(Draft d) async {
    final seconds = d.duration.inMilliseconds / 1000.0;
    final at = (d.focusSeconds ?? seconds * 0.35).clamp(0.0, seconds > 0.2 ? seconds - 0.2 : 0.0);
    try {
      final result = await runner.run(
        ffmpegExecutable,
        ['-y', '-hide_banner', '-ss', at.toStringAsFixed(2), '-i', d.videoPath, '-frames:v', '1', '-vf', 'scale=480:-2', d.thumbPath],
        timeout: const Duration(seconds: 20),
      );
      if (result.exitCode != 0) AppLogger.debug('Draft thumbnail failed: ${result.stderr}');
      notifyListeners();
    } catch (error) {
      AppLogger.debug('Draft thumbnail failed: $error');
    }
  }
}
