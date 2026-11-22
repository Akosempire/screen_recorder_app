import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'ffmpeg_binary.dart';
import 'ffmpeg_process_manager.dart';
import 'recording_recovery.dart';

/// untrunc (github.com/anthwlock/untrunc, GPL-2.0), shipped with the Windows
/// app in `untrunc\`. It rebuilds a video that was cut off before it was
/// finished (recordings made before crash-safe recording), using a working
/// video from the same computer as a model. Null where it isn't available.
String? get untruncExecutable {
  final env = Platform.environment['SR_UNTRUNC'];
  if (env != null && File(env).existsSync()) return env;
  final appDir = p.dirname(Platform.resolvedExecutable);
  for (final c in [
    p.join(appDir, 'untrunc', 'untrunc.exe'),
    p.join(appDir, 'untrunc', 'untrunc'),
  ]) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

/// Checks a repaired video really plays: FFmpeg can read it, it has some
/// length, and decoding the start gives few errors (a wrong model gives a
/// garbled picture and lots of errors).
Future<bool> looksPlayable(String path, ProcessRunner runner) async {
  final info = await runner.run(ffmpegExecutable, ['-hide_banner', '-i', path]);
  final probe = parseFfmpegInfo('${info.stderr}');
  if (probe == null) return false;
  final check = await runner.run(
    ffmpegExecutable,
    ['-hide_banner', '-v', 'error', '-i', path, '-t', '30', '-f', 'null', '-'],
    timeout: const Duration(minutes: 3),
  );
  final lines = '${check.stderr}'.split('\n').where((l) => l.trim().isNotEmpty).toList();
  final errors = lines.length;
  AppLogger.info('Repaired video check: ${probe.duration}, $errors decode error line(s)'
      '${lines.isEmpty ? '' : ', e.g. ${lines.first}'}');
  return errors < 25;
}

/// Tries to repair [broken] with each of [models] in turn (best match
/// first). Returns the repaired file, or null if none worked. [broken] is
/// never changed.
Future<String?> repairCutOffVideo(
  String broken, {
  required List<String> models,
  ProcessRunner runner = const ProcessRunner(),
  String? untrunc,
}) async {
  final tool = untrunc ?? untruncExecutable;
  if (tool == null) {
    AppLogger.warn('No repair tool found next to the app; leaving $broken as it is');
    return null;
  }
  final dir = p.dirname(broken);
  final name = p.basename(broken);
  var tried = 0;
  for (final model in models) {
    if (model == broken || !File(model).existsSync()) continue;
    if (++tried > 4) break;
    final before = DateTime.now().subtract(const Duration(seconds: 2));
    AppLogger.info('Repairing $broken using $model');
    try {
      final result = await runner.run(
        tool,
        [model, broken],
        workingDirectory: dir,
        timeout: const Duration(minutes: 30),
      );
      // Kept in the log Get help sends, so a failed repair can be looked into.
      final said = '${result.stdout}\n${result.stderr}'
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      AppLogger.info('Repair tool (exit ${result.exitCode}): ${said.length > 12 ? said.sublist(said.length - 12).join(' | ') : said.join(' | ')}');
    } catch (error) {
      AppLogger.warn('Repair tool failed to run: $error');
      return null;
    }
    // untrunc writes "<name>_fixed….mp4" next to the broken file.
    final outs = Directory(dir)
        .listSync()
        .whereType<File>()
        .where((f) {
          final n = p.basename(f.path);
          return n != name && n.startsWith(name.replaceAll('.mp4', '')) && n.contains('fixed') && f.lastModifiedSync().isAfter(before);
        })
        .toList()
      ..sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
    if (outs.isEmpty) {
      AppLogger.warn('Repair with $model produced no file');
      continue;
    }
    final out = outs.first.path;
    if (await looksPlayable(out, runner)) {
      AppLogger.info('Repaired $broken → $out');
      return out;
    }
    AppLogger.warn('Repair with $model didn\'t give a playable video; trying another model');
    for (final f in outs) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
  return null;
}
