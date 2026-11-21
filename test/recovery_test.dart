import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder_app/services/auto_zoom.dart';
import 'package:screen_recorder_app/services/cursor_tracker.dart';
import 'package:screen_recorder_app/services/draft_store.dart';
import 'package:screen_recorder_app/services/draft_zoom.dart';
import 'package:screen_recorder_app/services/ffmpeg_process_manager.dart';
import 'package:screen_recorder_app/services/recording_recovery.dart';

const _info = '''
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'segment_0.mp4':
  Duration: 02:13:05.40, start: 0.000000, bitrate: 2210 kb/s
  Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 1920x1080, 2080 kb/s, 30 fps, 30 tbr, 15360 tbn (default)
  Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 128 kb/s (default)
At least one output file must be specified
''';

/// FFmpeg stand-in: `-i` prints [_info]; concat / auto-zoom create their output.
class _FakeFfmpeg extends ProcessRunner {
  _FakeFfmpeg({this.info = _info, this.damaged = const {}});
  final String info;

  /// File names FFmpeg can't read (cut off while being written).
  final Set<String> damaged;

  /// What was asked to be joined, as the concat list said.
  String joined = '';
  final calls = <List<String>>[];

  @override
  Future<ProcessResult> run(String executable, List<String> arguments, {String? workingDirectory, Duration? timeout}) async {
    calls.add(arguments);
    if (arguments.contains('concat')) {
      joined = File(arguments[arguments.indexOf('-i') + 1]).readAsStringSync();
      File(arguments.last).writeAsBytesSync(List.filled(200 * 1024, 1));
      return ProcessResult(0, 0, '', '');
    }
    if (arguments.length == 3 && arguments[1] == '-i') {
      if (damaged.contains(p.basename(arguments[2]))) return ProcessResult(0, 1, '', 'moov atom not found');
      return ProcessResult(0, 1, '', info);
    }
    return ProcessResult(0, 1, '', 'no');
  }

  @override
  Future<ProcessResult> runStreaming(String executable, List<String> arguments,
      {required void Function(String line) onLine, String? workingDirectory}) async {
    calls.add(arguments);
    onLine('out_time_us=1000000');
    File(arguments.last).writeAsBytesSync(List.filled(1024, 7));
    return ProcessResult(0, 0, '', '');
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('recovery_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final old = DateTime.now().subtract(const Duration(hours: 5));

  File video(String dir, String name, {int kb = 200, DateTime? at}) {
    final f = File(p.join(tmp.path, dir, name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(kb * 1024, 0));
    f.setLastModifiedSync(at ?? old);
    return f;
  }

  test('reads length, size and sound from ffmpeg -i', () {
    final probe = parseFfmpegInfo(_info)!;
    expect(probe.duration, const Duration(hours: 2, minutes: 13, seconds: 5, milliseconds: 400));
    expect(probe.width, 1920);
    expect(probe.height, 1080);
    expect(probe.hasAudio, isTrue);
    expect(parseFfmpegInfo('moov atom not found\nInvalid data found when processing input'), isNull);
  });

  test('a file cut off mid-recording (written in pieces) is still readable', () {
    final probe = parseFfmpegInfo(_info.replaceFirst(RegExp(r'Duration: [^,]+'), 'Duration: N/A'))!;
    expect(probe.duration, Duration.zero, reason: 'length is found by reading the file through');
    expect(probe.width, 1920);
    expect(probe.hasAudio, isTrue);
  });

  test('finds recordings left in the temp folder, and skips what is not one', () async {
    // The class: stopped normally, then auto-zoom was cut off by shutdown.
    video('screen_recorder_aaa', 'segment_0.mp4', kb: 900);
    video('screen_recorder_aaa', 'autozoom.mp4', kb: 300);
    // Paused twice, merge never happened.
    for (var i = 0; i < 3; i++) {
      video('screen_recorder_bbb', 'segment_$i.mp4', at: old.add(Duration(minutes: i)));
    }
    // Merged after the pieces: use the merged file.
    video('screen_recorder_ccc', 'segment_0.mp4');
    video('screen_recorder_ccc', 'segment_1.mp4');
    video('screen_recorder_ccc', 'merged.mp4', at: old.add(const Duration(minutes: 5)));
    // Still recording right now: leave alone.
    video('screen_recorder_ddd', 'segment_0.mp4', at: DateTime.now());
    // Not recordings.
    video('screen_recorder_app', 'last_save_path.txt');
    video('screen_recorder_eee', 'segment_0.mp4', kb: 1);
    video('other_app', 'segment_0.mp4');

    final found = await findRecoverableRecordings(temp: tmp);
    final byDir = {for (final r in found) p.basename(r.dir.path): r.files.map(p.basename).toList()};
    expect(byDir, {
      'screen_recorder_aaa': ['segment_0.mp4'],
      'screen_recorder_bbb': ['segment_0.mp4', 'segment_1.mp4', 'segment_2.mp4'],
      'screen_recorder_ccc': ['merged.mp4'],
    });
  });

  test('a lost class comes back into Recordings, marked Recovered', () async {
    video('screen_recorder_aaa', 'segment_0.mp4', kb: 900);
    video('screen_recorder_aaa', 'autozoom.mp4', kb: 300);
    for (var i = 0; i < 2; i++) {
      video('screen_recorder_bbb', 'segment_$i.mp4', at: old.add(Duration(minutes: i)));
    }
    final store = DraftStore(root: Directory(p.join(tmp.path, 'recordings')), runner: _FakeFfmpeg());
    final runner = _FakeFfmpeg();
    final recovered = await recoverUnsavedRecordings(store: store, temp: tmp, runner: runner);

    expect(recovered, hasLength(2));
    for (final d in recovered) {
      expect(d.recovered, isTrue);
      expect(d.duration, const Duration(hours: 2, minutes: 13, seconds: 5, milliseconds: 400));
      expect(d.width, 1920);
      expect(File(d.videoPath).existsSync(), isTrue);
    }
    expect(Directory(p.join(tmp.path, 'screen_recorder_aaa')).existsSync(), isFalse, reason: 'temp folder cleaned up');
    expect(runner.calls.any((c) => c.contains('concat')), isTrue, reason: 'paused pieces are joined');

    final reloaded = DraftStore(root: Directory(p.join(tmp.path, 'recordings')));
    await reloaded.load();
    expect(reloaded.drafts.every((d) => d.recovered), isTrue);
  });

  test('paused, resumed, then an error: the readable pieces are still recovered', () async {
    for (var i = 0; i < 3; i++) {
      video('screen_recorder_err', 'segment_$i.mp4', at: old.add(Duration(minutes: i)));
    }
    final store = DraftStore(root: Directory(p.join(tmp.path, 'recordings')), runner: _FakeFfmpeg());
    final runner = _FakeFfmpeg(damaged: {'segment_2.mp4'});
    final recovered = await recoverUnsavedRecordings(store: store, temp: tmp, runner: runner);
    expect(recovered, hasLength(1));
    expect(runner.joined, contains('segment_0.mp4'));
    expect(runner.joined, contains('segment_1.mp4'));
    expect(runner.joined, isNot(contains('segment_2.mp4')), reason: 'the damaged piece is left out');
    expect(File(p.join(tmp.path, 'screen_recorder_err', 'segment_2.mp4')).existsSync(), isTrue,
        reason: 'a piece that could not be repaired is kept for later');
    expect(File(p.join(tmp.path, 'screen_recorder_err', 'segment_0.mp4')).existsSync(), isFalse,
        reason: 'what is in Recordings now is not recovered twice');
  });

  test('a piece cut off before it was finished is repaired and recovered', () async {
    final working = video('screen_recorder_old', 'segment_1.mp4', at: old.add(const Duration(minutes: 5)));
    video('screen_recorder_old', 'segment_0.mp4');
    final store = DraftStore(root: Directory(p.join(tmp.path, 'recordings')), runner: _FakeFfmpeg());
    final asked = <String>[];
    final recovered = await recoverUnsavedRecordings(
      store: store,
      temp: tmp,
      runner: _FakeFfmpeg(damaged: {'segment_0.mp4'}),
      repairer: (broken, models) async {
        asked.add(p.basename(broken));
        expect(models.first, working.path, reason: 'a piece from the same recording is the best model');
        final fixed = File('$broken.fixed.mp4')..writeAsBytesSync(List.filled(300 * 1024, 3));
        return fixed.path;
      },
    );
    expect(asked, ['segment_0.mp4']);
    expect(recovered, hasLength(1));
    expect(recovered.single.repaired, isTrue);
  });

  test('an unreadable leftover is left where it is', () async {
    video('screen_recorder_zzz', 'segment_0.mp4');
    final store = DraftStore(root: Directory(p.join(tmp.path, 'recordings')), runner: _FakeFfmpeg());
    final recovered = await recoverUnsavedRecordings(
      store: store,
      temp: tmp,
      runner: _FakeFfmpeg(info: 'moov atom not found'),
    );
    expect(recovered, isEmpty);
    expect(File(p.join(tmp.path, 'screen_recorder_zzz', 'segment_0.mp4')).existsSync(), isTrue);
  });

  group('auto-zoom after saving', () {
    PendingZoom plan(Duration d, {bool enabled = true}) => PendingZoom(
          log: CursorLog(
            [for (var i = 0; i < 120; i++) CursorSample(i / 30, 100.0 + i, 80)],
            const [CursorClick(1.5, 200, 120), CursorClick(2, 50, 60, right: true)],
          ),
          width: 640,
          height: 360,
          encoder: 'libx264',
          hasAudio: true,
          duration: d,
          enabled: enabled,
          settings: const AutoZoomSettings(maxZoom: 2.2, hold: 3, panTau: 0.3, zoomTau: 0.34),
        );

    test('only short recordings are zoomed right away, and only if it is on', () {
      expect(plan(const Duration(minutes: 5)).rightAway, isTrue);
      expect(plan(const Duration(hours: 2)).rightAway, isFalse);
      expect(plan(const Duration(minutes: 5), enabled: false).rightAway, isFalse);
    });

    test('the zoom plan survives a restart', () {
      final back = PendingZoom.fromJson(plan(const Duration(hours: 2)).toJson())!;
      expect(back.width, 640);
      expect(back.duration, const Duration(hours: 2));
      expect(back.log.samples, hasLength(120));
      expect(back.log.clicks.last.right, isTrue);
      expect(back.settings.maxZoom, 2.2);
      expect(back.settings.hold, 3);
    });

    test('applying it later keeps the original and swaps in the zoomed video', () async {
      final store = DraftStore(root: Directory(p.join(tmp.path, 'recordings')), runner: _FakeFfmpeg());
      final raw = video('in', 'raw.mp4');
      final draft = (await store.createFrom(
        video: raw.path,
        width: 640,
        height: 360,
        duration: const Duration(hours: 2),
        hasAudio: true,
      ))!;
      expect(canApplyAutoZoom(draft), isFalse, reason: 'no plan yet');
      await writeZoomPlan(draft, plan(const Duration(hours: 2)));
      expect(canApplyAutoZoom(draft), isTrue);

      final progress = <double>[];
      final done = await applyAutoZoomToDraft(draft, store: store, runner: _FakeFfmpeg(), onProgress: progress.add);
      expect(done, isTrue);
      expect(File(draft.originalPath).lengthSync(), 200 * 1024, reason: 'the recording as captured is kept');
      expect(File(draft.videoPath).lengthSync(), 1024, reason: 'the zoomed video is now the one exported');
      expect(canApplyAutoZoom(draft), isFalse);
    });
  });
}
