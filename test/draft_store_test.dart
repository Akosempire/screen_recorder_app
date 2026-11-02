import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/screens/editor_screen.dart';
import 'package:screen_recorder_app/services/draft_store.dart';
import 'package:screen_recorder_app/services/ffmpeg_process_manager.dart';
import 'package:screen_recorder_app/services/recording_edit.dart';
import 'package:screen_recorder_app/services/recording_library.dart';
import 'package:screen_recorder_app/widgets/recordings_shelf.dart';

/// FFmpeg stand-in: every call fails at once (no thumbnails in tests).
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

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('drafts_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<String> fakeVideo(String name, [String content = 'video']) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsString(content);
    return f.path;
  }

  test('a finished recording is moved into Recordings and survives a restart', () async {
    final store = DraftStore(root: Directory('${tmp.path}/recordings'), runner: const _NoFfmpeg());
    final video = await fakeVideo('zoomed.mp4', 'zoomed');
    final original = await fakeVideo('raw.mp4', 'raw');
    final draft = await store.createFrom(
      video: video,
      original: original,
      width: 1920,
      height: 1080,
      duration: const Duration(seconds: 42),
      hasAudio: true,
      focusSeconds: 3.5,
      now: DateTime(2026, 11, 2, 10, 42),
    );
    expect(draft, isNotNull);
    expect(File(video).existsSync(), isFalse, reason: 'moved out of the temp folder');
    expect(File(draft!.videoPath).readAsStringSync(), 'zoomed');
    expect(File(draft.originalPath).readAsStringSync(), 'raw');
    expect(draft.isExported, isFalse);
    expect(store.unexportedCount, 1);

    await store.saveEdits(draft.id, trimStart: 1, trimEnd: 40, cuts: const [EditRange(10, 12)]);
    await store.markExported(draft.id, '/videos/out.mp4');

    final again = DraftStore(root: Directory('${tmp.path}/recordings'), runner: const _NoFfmpeg());
    await again.load();
    expect(again.drafts, hasLength(1));
    final d = again.drafts.single;
    expect(d.duration, const Duration(seconds: 42));
    expect(d.width, 1920);
    expect(d.hasAudio, isTrue);
    expect(d.focusSeconds, 3.5);
    expect(d.trimStart, 1);
    expect(d.trimEnd, 40);
    expect(d.cuts, const [EditRange(10, 12)]);
    expect(d.exportedTo, ['/videos/out.mp4']);
    expect(d.hasEdits, isTrue);
    expect(again.unexportedCount, 0);
  });

  test('recording again keeps every earlier recording, newest first', () async {
    final store = DraftStore(root: Directory('${tmp.path}/recordings'), runner: const _NoFfmpeg());
    for (var i = 0; i < 3; i++) {
      await store.createFrom(
        video: await fakeVideo('r$i.mp4'),
        width: 100,
        height: 100,
        duration: const Duration(seconds: 5),
        hasAudio: false,
        now: DateTime(2026, 11, 2, 10, i),
      );
    }
    expect(store.drafts.map((d) => d.createdAt.minute), [2, 1, 0]);
    await store.delete(store.drafts[1].id);
    expect(store.drafts.map((d) => d.createdAt.minute), [2, 0]);
    final reloaded = DraftStore(root: Directory('${tmp.path}/recordings'));
    await reloaded.load();
    expect(reloaded.drafts, hasLength(2));
  });

  test('restore puts back saved trims and cuts', () {
    final edit = RecordingEdit(30)
      ..restore(trimStart: 2, trimEnd: 25, cuts: const [EditRange(10, 12), EditRange(5, 5.05)]);
    expect(edit.trimStart, 2);
    expect(edit.trimEnd, 25);
    expect(edit.cuts, const [EditRange(10, 12)], reason: 'too-short pieces are dropped');
    expect(edit.kept, const [EditRange(2, 10), EditRange(12, 25)]);
  });

  test('dates read naturally', () {
    final now = DateTime(2026, 11, 2, 15);
    expect(draftDateLabel(DateTime(2026, 11, 2, 9, 5), now: now), 'Today, 09:05');
    expect(draftDateLabel(DateTime(2026, 11, 1, 22, 30), now: now), 'Yesterday, 22:30');
    expect(draftDateLabel(DateTime(2026, 10, 20, 8, 0), now: now), '20 Oct, 08:00');
    expect(draftDateLabel(DateTime(2025, 10, 20, 8, 0), now: now), '20 Oct 2025, 08:00');
  });

  testWidgets('editor: big play button, and Save as draft keeps the edits', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recording = LastRecording(
      finalPath: '/no/such/recording.mp4',
      width: 1920,
      height: 1080,
      duration: const Duration(seconds: 20),
      hasAudio: true,
    );
    final previous = RecordingLibrary.instance.runner;
    RecordingLibrary.instance.runner = const _NoFfmpeg(); // no preview frames in tests
    addTearDown(() => RecordingLibrary.instance.runner = previous);
    final edit = RecordingEdit(20)..playhead = 10;
    RecordingEdit? saved;
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute<String>(
              builder: (_) => EditorScreen(
                recording: recording,
                initialEdit: edit,
                playback: false,
                onExport: (_) async => null,
                onSaveDraft: (e) async => saved = e,
              ),
            ));
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(); // the new route's first frame is off-stage
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.text('Play recording'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Save as draft'), findsOneWidget);

    await tester.tap(find.text('Add cut'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Save as draft'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(closed, isTrue);
    expect(saved, isNotNull);
    expect(saved!.cuts, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Recordings shelf lists drafts and opens one', (tester) async {
    final store = DraftStore(root: Directory('${tmp.path}/recordings'), runner: const _NoFfmpeg());
    Draft? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(8),
          child: RecordingsShelf(store: store, onOpen: (d) => opened = d),
        ),
      ),
    ));
    expect(find.textContaining('Your recordings will show up here'), findsOneWidget);

    await tester.runAsync(() async {
      await store.createFrom(
        video: await fakeVideo('a.mp4'),
        width: 100,
        height: 100,
        duration: const Duration(seconds: 65),
        hasAudio: false,
      );
    });
    await tester.pump();
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    expect(find.textContaining('not exported yet'), findsOneWidget);
    await tester.tap(find.text('Draft'));
    expect(opened, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
