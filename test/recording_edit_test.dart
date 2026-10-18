import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/services/ffmpeg_process_manager.dart';
import 'package:screen_recorder_app/screens/editor_screen.dart';
import 'package:screen_recorder_app/services/recording_background.dart';
import 'package:screen_recorder_app/services/recording_edit.dart';
import 'package:screen_recorder_app/services/recording_library.dart';
import 'package:screen_recorder_app/services/studio_save_service.dart';

void main() {
  group('keptRanges', () {
    test('no edits keeps everything', () {
      expect(keptRanges(10, 0, 10, const []), [const EditRange(0, 10)]);
    });

    test('trims and cuts, including overlapping and out-of-range cuts', () {
      final kept = keptRanges(30, 2, 28, const [
        EditRange(10, 12),
        EditRange(11, 14), // overlaps the first
        EditRange(0, 3), // inside the trimmed start
        EditRange(27.9, 40), // past the end
      ]);
      expect(kept, [const EditRange(3, 10), const EditRange(14, 27.9)]);
    });

    test('drops slivers shorter than minPiece', () {
      expect(keptRanges(10, 0, 10, const [EditRange(0.1, 9.95)]), isEmpty);
    });
  });

  test('nextPlayableTime skips cuts and stops at the end', () {
    const kept = [EditRange(2, 10), EditRange(14, 20)];
    expect(nextPlayableTime(kept, 0), 2); // before the start trim
    expect(nextPlayableTime(kept, 5), 5); // inside a kept part
    expect(nextPlayableTime(kept, 11), 14); // inside a cut
    expect(nextPlayableTime(kept, 19.99), isNull); // at the very end
    expect(nextPlayableTime(kept, 25), isNull);
    expect(nextPlayableTime(const [], 1), isNull);
  });

  group('RecordingEdit', () {
    test('trim handles keep at least minKeep apart and stay in range', () {
      final e = RecordingEdit(20);
      e.trimStart = -5;
      expect(e.trimStart, 0);
      e.trimEnd = 100;
      expect(e.trimEnd, 20);
      e.trimStart = 19.9;
      expect(e.trimStart, 20 - RecordingEdit.minKeep);
      e.trimEnd = 0;
      expect(e.trimEnd, e.trimStart + RecordingEdit.minKeep);
      expect(e.isEdited, isTrue);
      e.reset();
      expect(e.isEdited, isFalse);
      expect(e.exportSegments, isNull);
    });

    test('add, resize and remove a cut', () {
      final e = RecordingEdit(42)..playhead = 21;
      final i = e.addCutAtPlayhead();
      expect(e.cuts[i], const EditRange(20, 22));
      e.setCut(i, 18, 24.5);
      expect(e.kept, [const EditRange(0, 18), const EditRange(24.5, 42)]);
      expect(e.keptDuration, closeTo(35.5, 1e-9));
      e.setCut(i, 30, 30.05); // too short: grows to minPiece
      expect(e.cuts[i].length, closeTo(RecordingEdit.minPiece, 1e-9));
      e.removeCut(i);
      expect(e.cuts, isEmpty);
    });

    test('a cut near the end stays inside the video', () {
      final e = RecordingEdit(10)..playhead = 9.9;
      final i = e.addCutAtPlayhead();
      expect(e.cuts[i].end, lessThanOrEqualTo(10));
      expect(e.cuts[i].length, closeTo(1.0, 1e-9)); // a tenth of a 10 s video
    });
  });

  group('buildExportArgs with edits', () {
    final segments = [const EditRange(0.5, 1.5), const EditRange(2.5, 3.8)];

    test('trims, joins with sound and adds the background', () {
      final layout = layoutBackground(1920, 1080, const BackgroundSpec(kind: BackgroundKind.preset));
      final a = buildExportArgs(
        source: 'in.mp4',
        output: 'out.mp4',
        settings: ExportSettings(fileName: 'x', folder: '.', segments: segments),
        height: 1080,
        hasAudio: true,
        background: layout,
        backgroundFrame: 'frame.png',
      )!;
      expect(a.sublist(0, 8), ['-y', '-hide_banner', '-i', 'in.mp4', '-loop', '1', '-i', 'frame.png']);
      final graph = a[a.indexOf('-filter_complex') + 1];
      expect(
        graph,
        '[0:v]trim=start=0.500:end=1.500,setpts=PTS-STARTPTS[v0];'
        '[0:a]atrim=start=0.500:end=1.500,asetpts=PTS-STARTPTS[a0];'
        '[0:v]trim=start=2.500:end=3.800,setpts=PTS-STARTPTS[v1];'
        '[0:a]atrim=start=2.500:end=3.800,asetpts=PTS-STARTPTS[a1];'
        '[v0][a0][v1][a1]concat=n=2:v=1:a=1[vcat][acat];'
        '[vcat]scale=1612:906:flags=lanczos,setsar=1,pad=1920:1080:154:88:color=black[rec];'
        '[rec][1:v]overlay=0:0:shortest=1,format=yuv420p[out]',
      );
      expect(a, containsAllInOrder(['-map', '[out]', '-map', '[acat]', '-c:a', 'aac']));
    });

    test('without sound or background: video-only join, scale and 15 fps', () {
      final a = buildExportArgs(
        source: 'in.mp4',
        output: 'out.mp4',
        settings: ExportSettings(
          fileName: 'x',
          folder: '.',
          segments: segments,
          keepSound: false,
          resolution: ExportResolution.p720,
          frameRate: ExportFrameRate.fps15,
        ),
        height: 1080,
        hasAudio: true,
      )!;
      final graph = a[a.indexOf('-filter_complex') + 1];
      expect(graph, contains('[v0][v1]concat=n=2:v=1:a=0[vcat]'));
      expect(graph, endsWith('[vcat]scale=-2:720:flags=lanczos,fps=15,format=yuv420p[out]'));
      expect(graph, isNot(contains('atrim')));
      expect(a, contains('-an'));
      expect(a, isNot(contains('-loop')));
    });
  });

  testWidgets('Editor fits the smallest window and edits work', (tester) async {
    final library = RecordingLibrary.instance;
    final realRunner = library.runner;
    library.runner = const _NoFfmpeg();
    addTearDown(() => library.runner = realRunner);
    tester.view.physicalSize = const Size(860, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recording = LastRecording(
      finalPath: '/no/such/recording.mp4',
      width: 1920,
      height: 1080,
      duration: const Duration(seconds: 42),
      hasAudio: true,
    );
    final edit = RecordingEdit(42)..playhead = 21;
    List<EditRange>? exported;
    await tester.pumpWidget(MaterialApp(
      home: EditorScreen(
        recording: recording,
        initialEdit: edit,
        playback: false,
        onExport: (segments) async {
          exported = segments;
          return null;
        },
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    expect(find.text('Edit your recording'), findsOneWidget);

    await tester.tap(find.text('Add cut'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(edit.cuts, hasLength(1));
    expect(find.byTooltip('Remove this cut'), findsOneWidget);

    await tester.tap(find.text('Export…'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(exported, [const EditRange(0, 20), const EditRange(22, 42)]);

    await tester.tap(find.byTooltip('Remove this cut'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(edit.cuts, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

/// Stand-in for FFmpeg: every call fails at once (no frames in tests).
class _NoFfmpeg extends ProcessRunner {
  const _NoFfmpeg();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
  }) async =>
      ProcessResult(0, 1, '', 'no ffmpeg in tests');
}
