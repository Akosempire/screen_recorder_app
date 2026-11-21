import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'draft_store.dart';
import 'ffmpeg_binary.dart';
import 'ffmpeg_process_manager.dart';
import 'recording_repair.dart';

/// A recording FFmpeg finished writing in the temporary folder, but which the
/// app never moved to Recordings (e.g. the computer was turned off while it
/// was being processed, or the app was closed or crashed).
class RecoverableRecording {
  const RecoverableRecording({required this.dir, required this.files, required this.modified});

  /// The `screen_recorder_…` session folder.
  final Directory dir;

  /// The video, or the pieces to join (paused recordings), in order.
  final List<String> files;
  final DateTime modified;
}

/// What FFmpeg says about a video (from `ffmpeg -i`).
class VideoProbe {
  const VideoProbe({required this.duration, required this.width, required this.height, required this.hasAudio});
  final Duration duration;
  final int width;
  final int height;
  final bool hasAudio;
}

/// Reads length, size and sound from `ffmpeg -i` output, or null if FFmpeg
/// couldn't read the file (for example, it was cut off while being written).
VideoProbe? parseFfmpegInfo(String stderr) {
  final d = RegExp(r'Duration: (\d+):(\d\d):(\d\d)(?:\.(\d+))?').firstMatch(stderr);
  final v = RegExp(r'Stream #\S+.*Video: .*?(\d{2,5})x(\d{2,5})').firstMatch(stderr);
  if (v == null) return null;
  if (d == null) {
    // A file cut off while being written in pieces can still be read, but
    // FFmpeg may not know its length up front ("Duration: N/A").
    if (!stderr.contains('Duration: N/A')) return null;
    return VideoProbe(
      duration: Duration.zero,
      width: int.parse(v.group(1)!),
      height: int.parse(v.group(2)!),
      hasAudio: RegExp(r'Stream #\S+.*Audio: ').hasMatch(stderr),
    );
  }
  final frac = d.group(4) ?? '0';
  final ms = (int.parse(frac.padRight(3, '0').substring(0, 3)));
  final duration = Duration(
    hours: int.parse(d.group(1)!),
    minutes: int.parse(d.group(2)!),
    seconds: int.parse(d.group(3)!),
    milliseconds: ms,
  );
  return VideoProbe(
    duration: duration,
    width: int.parse(v.group(1)!),
    height: int.parse(v.group(2)!),
    hasAudio: RegExp(r'Stream #\S+.*Audio: ').hasMatch(stderr),
  );
}

/// Session folders of ours that are not recordings.
const _notSessions = {'screen_recorder_app', 'screen_recorder_demo_recordings'};

/// Finds unsaved recordings in [temp] (the system temp folder by default).
/// Folders touched in the last [minAge] are skipped: they may belong to a
/// recording that's still going.
Future<List<RecoverableRecording>> findRecoverableRecordings({
  Directory? temp,
  Duration minAge = const Duration(minutes: 2),
  DateTime? now,
}) async {
  final root = temp ?? Directory.systemTemp;
  final out = <RecoverableRecording>[];
  final at = now ?? DateTime.now();
  if (!await root.exists()) return out;
  await for (final entry in root.list(followLinks: false)) {
    if (entry is! Directory) continue;
    final name = p.basename(entry.path);
    if (!name.startsWith('screen_recorder_') || _notSessions.contains(name)) continue;
    try {
      final files = <File>[];
      await for (final f in entry.list(followLinks: false)) {
        if (f is File) files.add(f);
      }
      bool usable(File f) => f.lengthSync() > 64 * 1024;
      File? named(String n) {
        for (final f in files) {
          if (p.basename(f.path) == n && usable(f)) return f;
        }
        return null;
      }

      // merged.mp4 is complete only if it's newer than every piece.
      final segments = files.where((f) => RegExp(r'^segment_(\d+)\.mp4$').hasMatch(p.basename(f.path)) && usable(f)).toList()
        ..sort((a, b) => _index(a).compareTo(_index(b)));
      final merged = named('merged.mp4');
      List<String> chosen;
      if (merged != null &&
          segments.every((s) => !s.lastModifiedSync().isAfter(merged.lastModifiedSync()))) {
        chosen = [merged.path];
      } else {
        chosen = segments.map((f) => f.path).toList();
      }
      if (chosen.isEmpty) continue;
      final modified = files.map((f) => f.lastModifiedSync()).reduce((a, b) => a.isAfter(b) ? a : b);
      if (at.difference(modified) < minAge) continue;
      out.add(RecoverableRecording(dir: entry, files: chosen, modified: modified));
    } catch (error) {
      AppLogger.debug('Skipping ${entry.path}: $error');
    }
  }
  out.sort((a, b) => a.modified.compareTo(b.modified));
  return out;
}

int _index(File f) => int.tryParse(RegExp(r'(\d+)').firstMatch(p.basename(f.path))?.group(1) ?? '') ?? 0;

/// Joins pieces (if any), checks FFmpeg can read the video, and moves it into
/// Recordings as a draft marked "Recovered". The temporary folder is removed
/// afterwards. Returns the draft, or null if the video couldn't be read (the
/// files are then left where they are).
Future<Draft?> recoverRecording(
  RecoverableRecording r, {
  required DraftStore store,
  ProcessRunner runner = const ProcessRunner(),
  Future<String?> Function(String broken, List<String> models)? repairer,
}) async {
  // Check each piece. One FFmpeg can't read was cut off while being written
  // (recordings made before crash-safe recording): repair it if possible,
  // otherwise leave it out so the good pieces are still recovered.
  final readable = <String>[];
  final broken = <String>[];
  for (final f in r.files) {
    final info = await runner.run(ffmpegExecutable, ['-hide_banner', '-i', f]);
    (parseFfmpegInfo('${info.stderr}') != null ? readable : broken).add(f);
  }
  final repaired = <String, String>{};
  if (broken.isNotEmpty && (repairer != null || untruncExecutable != null)) {
    final models = [
      ...readable,
      for (final d in store.drafts) d.hasOriginal ? d.originalPath : d.videoPath,
    ];
    for (final b in broken) {
      final fixed = await (repairer ?? (String v, List<String> m) => repairCutOffVideo(v, models: m, runner: runner))(b, models);
      if (fixed != null) repaired[b] = fixed;
    }
  }
  final files = [
    for (final f in r.files)
      if (readable.contains(f)) f else if (repaired[f] != null) repaired[f]!,
  ];
  if (files.isEmpty) {
    AppLogger.warn('Unreadable leftover recording in ${r.dir.path}; leaving it in place');
    return null;
  }
  var video = files.first;
  if (files.length > 1) {
    final list = File(p.join(r.dir.path, 'recover_list.txt'));
    await list.writeAsString(files.map((f) => "file '${f.replaceAll("'", r"'\''")}'").join('\n'));
    final joined = p.join(r.dir.path, 'recovered.mp4');
    final result = await runner.run(
      ffmpegExecutable,
      ['-y', '-hide_banner', '-f', 'concat', '-safe', '0', '-i', list.path, '-c', 'copy', joined],
    );
    if (result.exitCode == 0 && await File(joined).exists()) {
      video = joined;
    } else {
      AppLogger.warn('Could not join the pieces of ${r.dir.path}; recovering the longest one');
      video = (files.toList()..sort((a, b) => File(b).lengthSync().compareTo(File(a).lengthSync()))).first;
    }
  }
  final info = await runner.run(ffmpegExecutable, ['-hide_banner', '-i', video]);
  var probe = parseFfmpegInfo('${info.stderr}');
  if (probe != null && probe.duration == Duration.zero) {
    // Length unknown: read the file through once to find it.
    final pass = await runner.run(ffmpegExecutable, ['-hide_banner', '-i', video, '-map', '0:v:0', '-c', 'copy', '-f', 'null', '-']);
    final times = RegExp(r'time=(\d+):(\d\d):(\d\d)(?:\.(\d+))?').allMatches('${pass.stderr}').toList();
    if (times.isNotEmpty) {
      final t = times.last;
      final frac = (t.group(4) ?? '0').padRight(3, '0').substring(0, 3);
      probe = VideoProbe(
        duration: Duration(
          hours: int.parse(t.group(1)!),
          minutes: int.parse(t.group(2)!),
          seconds: int.parse(t.group(3)!),
          milliseconds: int.parse(frac),
        ),
        width: probe.width,
        height: probe.height,
        hasAudio: probe.hasAudio,
      );
    }
  }
  if (probe == null || probe.duration < const Duration(seconds: 1)) {
    AppLogger.warn('Unreadable leftover recording in ${r.dir.path}; leaving it in place');
    return null;
  }
  final draft = await store.createFrom(
    video: video,
    width: probe.width,
    height: probe.height,
    duration: probe.duration,
    hasAudio: probe.hasAudio,
    now: r.modified,
    recovered: true,
    repaired: repaired.isNotEmpty,
  );
  if (draft != null) {
    try {
      await r.dir.delete(recursive: true);
    } catch (_) {}
    AppLogger.info('Recovered ${probe.duration} recording from ${r.dir.path}');
  }
  return draft;
}

/// Run once at start-up: brings back every unsaved recording it can.
Future<List<Draft>> recoverUnsavedRecordings({
  DraftStore? store,
  Directory? temp,
  ProcessRunner runner = const ProcessRunner(),
  Future<String?> Function(String broken, List<String> models)? repairer,
}) async {
  final drafts = store ?? DraftStore.instance;
  final out = <Draft>[];
  try {
    for (final r in await findRecoverableRecordings(temp: temp)) {
      final d = await recoverRecording(r, store: drafts, runner: runner, repairer: repairer);
      if (d != null) out.add(d);
    }
  } catch (error, stack) {
    AppLogger.error('Recovering unsaved recordings failed', error, stack);
  }
  return out;
}
