import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/app.dart';
import 'package:screen_recorder_app/controllers/recording_controller.dart';
import 'package:screen_recorder_app/models/display_server.dart';
import 'package:screen_recorder_app/models/screen_region.dart';
import 'package:screen_recorder_app/screens/region_selection_screen.dart';
import 'package:screen_recorder_app/screens/recording_screen.dart';
import 'package:screen_recorder_app/screens/home_screen.dart';
import 'package:screen_recorder_app/models/recording_state.dart';
import 'package:screen_recorder_app/services/file_save_service.dart';
import 'package:screen_recorder_app/services/native_window.dart';
import 'package:screen_recorder_app/services/screen_recorder.dart';
import 'package:screen_recorder_app/services/selector_backdrop.dart';
import 'package:screen_recorder_app/services/window_coordinator.dart';
import 'package:screen_recorder_app/widgets/recording_controls.dart';
import 'package:screen_recorder_app/widgets/selection_rectangle.dart';

class _NoopRecorder implements ScreenRecorder {
  @override
  String get backendName => 'test';

  @override
  bool get isRecording => false;

  @override
  Future<void> start(
    ScreenRegion region, {
    bool recordMicrophone = false,
  }) async {}

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

  testWidgets('opening the selector does not setState during build',
      (tester) async {
    final controller = RecordingController(
      recorder: _NoopRecorder(),
      fileSaveService: _NoopSave(),
      geometry: _geometry,
    );
    controller.beginSelection();

    await tester.pumpWidget(
      ScreenRecorderApp(
        controller: controller,
        manageWindows: false,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Record'), findsOneWidget);
  });

  testWidgets('region selector has a microphone switch', (tester) async {
    var microphone = false;
    const geometry = DesktopGeometry(
      displayServer: DisplayServer.x11,
      monitors: [
        MonitorInfo(
          name: 'eDP-1',
          x: 0,
          y: 0,
          width: 1920,
          height: 1080,
          primary: true,
        ),
      ],
      minX: 0,
      minY: 0,
      width: 1920,
      height: 1080,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RegionSelectionScreen(
          geometry: geometry,
          onRecord: (_) {},
          onCancel: () {},
          recordMicrophone: microphone,
          onRecordMicrophoneChanged: (value) => microphone = value,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Microphone'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(microphone, isTrue);
  });

  testWidgets('snapshot selector paints the still under the whole overlay',
      (tester) async {
    final snapshot = File(
      '${Directory.systemTemp.path}/sr_widget_snap_missing.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RegionSelectionScreen(
          geometry: _geometry,
          snapshot: snapshot,
          onRecord: (_) {},
          onCancel: () {},
        ),
      ),
    );

    expect(find.byType(Image), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is SelectionDimPainter,
      ),
      findsOneWidget,
    );
  });

  testWidgets('live selector has no still and no opaque fill under the hole',
      (tester) async {
    final snapshot = File(
      '${Directory.systemTemp.path}/sr_widget_live_unused.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RegionSelectionScreen(
          geometry: _geometry,
          snapshot: snapshot,
          backdrop: SelectorBackdrop.liveHole,
          onRecord: (_) {},
          onCancel: () {},
        ),
      ),
    );

    expect(find.byType(Image), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox && widget.color == const Color(0xFF111111),
      ),
      findsNothing,
    );
    expect(
      find.textContaining('Desktop preview unavailable'),
      findsNothing,
    );
    expect(find.byType(Listener), findsWidgets);
  });

  testWidgets('Start Recording reveals the selector after it is built',
      (tester) async {
    final controller = RecordingController(
      recorder: _NoopRecorder(),
      fileSaveService: _NoopSave(),
      geometry: _geometry,
    );
    final windows = _FakeCoordinator();

    await tester.pumpWidget(
      ScreenRecorderApp(
        controller: controller,
        windowCoordinator: windows,
        nativeWindow: _StubNativeWindow(),
        manageWindows: true,
      ),
    );

    await tester.tap(find.text('Start Recording'));
    await tester.pump();
    await tester.pump();

    expect(windows.enterCalls, 1);
    expect(find.byType(RegionSelectionScreen), findsOneWidget);
    await tester.pump();
    expect(windows.revealCalls, 1);
    expect(windows.showHomeCalls, 0);
  });

  testWidgets('failed enter does not reveal the selector', (tester) async {
    final controller = RecordingController(
      recorder: _NoopRecorder(),
      fileSaveService: _NoopSave(),
      geometry: _geometry,
    );
    final windows = _FakeCoordinator()..throwOnEnter = true;

    await tester.pumpWidget(
      ScreenRecorderApp(
        controller: controller,
        windowCoordinator: windows,
        nativeWindow: _StubNativeWindow(),
        manageWindows: true,
      ),
    );

    await tester.tap(find.text('Start Recording'));
    await tester.pump();
    await tester.pump();

    expect(windows.enterCalls, 1);
    expect(windows.revealCalls, 0);
    expect(windows.showHomeCalls, 1);
    expect(find.text('Start Recording'), findsOneWidget);
  });

  testWidgets('Start Recording is ignored while the selector is ready',
      (tester) async {
    final controller = RecordingController(
      recorder: _NoopRecorder(),
      fileSaveService: _NoopSave(),
      geometry: _geometry,
    );
    controller.beginSelection();
    controller.updateReadyRegion(
      const ScreenRegion(x: 0, y: 0, width: 400, height: 400),
    );
    expect(controller.state, RecordingState.ready);
    expect(controller.canBeginSelection, isTrue);

    final windows = _FakeCoordinator();
    await tester.pumpWidget(
      ScreenRecorderApp(
        controller: controller,
        windowCoordinator: windows,
        nativeWindow: _StubNativeWindow(),
        manageWindows: true,
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    await tester.pump();

    expect(windows.enterCalls, 0);
    expect(windows.revealCalls, 0);
    expect(find.byType(RegionSelectionScreen), findsOneWidget);
  });

  testWidgets('recording screen paints only the compact chip', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = RecordingController(
      recorder: _NoopRecorder(),
      fileSaveService: _NoopSave(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RecordingScreen(
          controller: controller,
          onPauseResume: () {},
          onStop: () {},
        ),
      ),
    );

    expect(find.byType(RecordingControls), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Stop'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
    expect(find.byType(Scaffold), findsNothing);

    final chip = tester.getSize(find.byType(RecordingControls));
    expect(chip.width, lessThan(WindowCoordinator.recordingSize.width + 8));
    expect(chip.height, lessThan(WindowCoordinator.recordingSize.height + 8));
    expect(chip.width, lessThan(400));
    expect(chip.height, lessThan(56));
  });

  testWidgets('selector action bar does not overflow in a narrow window',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 124,
          height: 40,
          child: RegionSelectionScreen(
            geometry: _geometry,
            onRecord: (_) {},
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('home screen does not overflow at the recording chip size',
      (tester) async {
    final controller = RecordingController(
      recorder: _NoopRecorder(),
      fileSaveService: _NoopSave(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: WindowCoordinator.recordingSize.width,
          height: WindowCoordinator.recordingSize.height,
          child: HomeScreen(
            controller: controller,
            onStartRecording: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Start Recording'), findsOneWidget);
  });
}

const _geometry = DesktopGeometry(
  displayServer: DisplayServer.x11,
  monitors: [
    MonitorInfo(
      name: 'eDP-1',
      x: 0,
      y: 0,
      width: 1920,
      height: 1080,
      primary: true,
    ),
  ],
  minX: 0,
  minY: 0,
  width: 1920,
  height: 1080,
);

class _StubNativeWindow extends NativeWindowService {
  @override
  Future<AlphaProbe> probe() async => AlphaProbe.unavailable;

  @override
  Future<String> parentWindowHandle() async => '';
}

class _FakeCoordinator extends WindowCoordinator {
  _FakeCoordinator() : super(nativeWindow: _StubNativeWindow());

  int enterCalls = 0;
  int revealCalls = 0;
  int showHomeCalls = 0;
  bool throwOnEnter = false;

  @override
  Future<File?> enterSelection(
    DesktopGeometry geometry, {
    SelectorBackdrop backdrop = SelectorBackdrop.snapshot,
  }) async {
    enterCalls += 1;
    if (throwOnEnter) {
      throw StateError('enter failed');
    }
    return null;
  }

  @override
  Future<void> revealSelector() async {
    revealCalls += 1;
  }

  @override
  Future<void> showHome() async {
    showHomeCalls += 1;
  }
}
