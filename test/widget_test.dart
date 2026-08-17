import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/app.dart';
import 'package:screen_recorder_app/controllers/recording_controller.dart';
import 'package:screen_recorder_app/models/screen_region.dart';
import 'package:screen_recorder_app/services/file_save_service.dart';
import 'package:screen_recorder_app/services/screen_recorder.dart';

class _NoopRecorder implements ScreenRecorder {
  @override
  String get backendName => 'test';

  @override
  bool get isRecording => false;

  @override
  Future<void> start(ScreenRegion region) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<String?> stop() async => null;
}

class _NoopSave implements FileSaveService {
  @override
  Future<String?> chooseSaveLocation({
    String suggestedName = 'recording.mp4',
    String? initialDirectory,
  }) async {
    return null;
  }
}

void main() {
  testWidgets('home screen shows start recording and status', (tester) async {
    final controller = RecordingController(
      recorder: _NoopRecorder(),
      fileSaveService: _NoopSave(),
    );

    await tester.pumpWidget(
      ScreenRecorderApp(
        controller: controller,
        manageWindows: false,
      ),
    );

    expect(find.text('Start Recording'), findsOneWidget);
    expect(find.text('Status: Ready'), findsOneWidget);
    expect(find.textContaining('Ctrl+Shift+R'), findsOneWidget);
  });
}
