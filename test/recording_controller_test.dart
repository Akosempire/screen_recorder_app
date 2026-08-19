import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/controllers/recording_controller.dart';
import 'package:screen_recorder_app/models/recorder_exception.dart';
import 'package:screen_recorder_app/models/recording_state.dart';
import 'package:screen_recorder_app/models/screen_region.dart';
import 'package:screen_recorder_app/services/file_save_service.dart';
import 'package:screen_recorder_app/services/last_save_path_store.dart';
import 'package:screen_recorder_app/services/screen_recorder.dart';

class FakeScreenRecorder implements ScreenRecorder {
  ScreenRegion? started;
  int pauseCount = 0;
  int resumeCount = 0;
  int stopCount = 0;
  bool failStart = false;
  String? stopPath = '/tmp/fake-recording.mp4';

  @override
  String get backendName => 'fake';

  @override
  bool get isRecording => started != null && stopCount == 0;

  @override
  Future<void> start(ScreenRegion region) async {
    if (failStart) {
      throw const RecorderException(userMessage: 'FFmpeg failed to start.');
    }
    started = region;
  }

  @override
  Future<void> pause() async {
    pauseCount += 1;
  }

  @override
  Future<void> resume() async {
    resumeCount += 1;
  }

  @override
  Future<String?> stop() async {
    stopCount += 1;
    return stopPath;
  }
}

class FakeSaveService implements FileSaveService {
  String? path = '/tmp/saved.mp4';
  String? lastSuggestedName;
  String? lastInitialDirectory;

  @override
  Future<String?> chooseSaveLocation({
    String suggestedName = 'recording.mp4',
    String? initialDirectory,
  }) async {
    lastSuggestedName = suggestedName;
    lastInitialDirectory = initialDirectory;
    return path;
  }
}

class FakeStorage implements RecordingStorage {
  final Set<String> files;
  String? persistedSource;
  String? persistedDestination;
  bool throwOnPersist = false;

  FakeStorage({Set<String>? files})
      : files = files ?? {'/tmp/fake-recording.mp4'};

  @override
  Future<bool> exists(String path) async => files.contains(path);

  @override
  Future<void> persist(String sourcePath, String destinationPath) async {
    if (throwOnPersist) {
      throw const FileSystemFailure();
    }
    persistedSource = sourcePath;
    persistedDestination = destinationPath;
    files.add(destinationPath);
  }
}

class FileSystemFailure implements Exception {
  const FileSystemFailure();
}

RecordingController buildController({
  FakeScreenRecorder? recorder,
  FakeSaveService? save,
  FakeStorage? storage,
  LastSavePathStore? lastSavePathStore,
}) {
  return RecordingController(
    recorder: recorder ?? FakeScreenRecorder(),
    fileSaveService: save ?? FakeSaveService(),
    storage: storage ?? FakeStorage(),
    lastSavePathStore: lastSavePathStore,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('follows idle → selecting → ready → recording → paused → recording → stop → save → completed',
      () async {
    final recorder = FakeScreenRecorder();
    final save = FakeSaveService();
    final storage = FakeStorage();
    final controller = buildController(
      recorder: recorder,
      save: save,
      storage: storage,
    );

    expect(controller.state, RecordingState.idle);

    controller.beginSelection();
    expect(controller.state, RecordingState.selectingRegion);

    controller.updateReadyRegion(
      const ScreenRegion(x: 100, y: 80, width: 800, height: 600),
    );
    expect(controller.state, RecordingState.ready);

    await controller.startRecording();
    expect(controller.state, RecordingState.recording);
    expect(recorder.started?.width, 800);

    await controller.pause();
    expect(controller.state, RecordingState.paused);
    expect(recorder.pauseCount, 1);

    await controller.resume();
    expect(controller.state, RecordingState.recording);
    expect(recorder.resumeCount, 1);

    await controller.stopAndSave();
    expect(controller.state, RecordingState.completed);
    expect(recorder.stopCount, 1);
    expect(storage.persistedDestination, '/tmp/saved.mp4');
    expect(controller.outputPath, '/tmp/saved.mp4');
  });

  test('rejects pause while idle', () {
    final controller = buildController();
    expect(
      () => controller.pause(),
      throwsA(isA<InvalidStateException>()),
    );
    expect(controller.state, RecordingState.idle);
  });

  test('rejects start while paused', () async {
    final controller = buildController();
    controller.beginSelection();
    controller.updateReadyRegion(
      const ScreenRegion(x: 0, y: 0, width: 400, height: 400),
    );
    await controller.startRecording();
    await controller.pause();
    expect(controller.canBeginSelection, isFalse);
    expect(controller.canStartRecording, isFalse);
    expect(
      () => controller.startRecording(),
      throwsA(isA<InvalidStateException>()),
    );
  });

  test('keeps the recording when the save dialog is cancelled', () async {
    final save = FakeSaveService()..path = null;
    final storage = FakeStorage();
    final controller = buildController(save: save, storage: storage);

    controller.beginSelection();
    controller.updateReadyRegion(
      const ScreenRegion(x: 0, y: 0, width: 400, height: 400),
    );
    await controller.startRecording();
    await controller.stopAndSave();

    expect(controller.state, RecordingState.completed);
    expect(controller.unsavedPath, '/tmp/fake-recording.mp4');
    expect(storage.persistedDestination, isNull);
    expect(controller.statusDetail, contains('kept at'));
  });

  test('opens the save dialog in the last saved folder', () async {
    final save = FakeSaveService();
    final store = MemoryLastSavePathStore();
    final controller = buildController(
      save: save,
      lastSavePathStore: store,
    );

    Future<void> recordAndStop({required String destination}) async {
      save.path = destination;
      controller.beginSelection();
      controller.updateReadyRegion(
        const ScreenRegion(x: 0, y: 0, width: 400, height: 400),
      );
      await controller.startRecording();
      await controller.stopAndSave();
    }

    await recordAndStop(destination: '/home/user/Videos/clip.mp4');
    expect(save.lastInitialDirectory, isNull);
    expect(await store.lastDirectory(), '/home/user/Videos');

    await recordAndStop(destination: '/home/user/Videos/clip2.mp4');
    expect(save.lastInitialDirectory, '/home/user/Videos');
  });

  test('uses a previously remembered folder on the first save of a session', () async {
    final save = FakeSaveService();
    final controller = buildController(
      save: save,
      lastSavePathStore: MemoryLastSavePathStore(
        initialDirectory: '/home/user/Videos',
      ),
    );

    controller.beginSelection();
    controller.updateReadyRegion(
      const ScreenRegion(x: 0, y: 0, width: 400, height: 400),
    );
    await controller.startRecording();
    await controller.stopAndSave();

    expect(save.lastInitialDirectory, '/home/user/Videos');
  });

  test('does not remember a folder when the save dialog is cancelled', () async {
    final save = FakeSaveService()..path = null;
    final store = MemoryLastSavePathStore();
    final controller = buildController(
      save: save,
      lastSavePathStore: store,
    );

    controller.beginSelection();
    controller.updateReadyRegion(
      const ScreenRegion(x: 0, y: 0, width: 400, height: 400),
    );
    await controller.startRecording();
    await controller.stopAndSave();

    expect(await store.lastDirectory(), isNull);
  });

  test('saves GNOME webm recordings without renaming them to mp4', () async {
    final recorder = FakeScreenRecorder()..stopPath = '/tmp/fake-recording.webm';
    final save = FakeSaveService()..path = '/home/user/Videos/out.mp4';
    final storage = FakeStorage(files: {'/tmp/fake-recording.webm'});
    final controller = buildController(
      recorder: recorder,
      save: save,
      storage: storage,
    );

    controller.beginSelection();
    controller.updateReadyRegion(
      const ScreenRegion(x: 0, y: 0, width: 400, height: 400),
    );
    await controller.startRecording();
    await controller.stopAndSave();

    expect(save.lastSuggestedName, endsWith('.webm'));
    expect(storage.persistedDestination, '/home/user/Videos/out.webm');
    expect(controller.outputPath, '/home/user/Videos/out.webm');
  });

  test('cancel selection returns to idle', () {
    final controller = buildController();
    controller.beginSelection();
    controller.cancelSelection();
    expect(controller.state, RecordingState.idle);
    expect(controller.region, isNull);
  });
}
