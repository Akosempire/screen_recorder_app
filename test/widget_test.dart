import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/app.dart';
import 'package:screen_recorder_app/controllers/recording_controller.dart';
import 'package:screen_recorder_app/models/display_server.dart';
import 'package:screen_recorder_app/models/screen_region.dart';
import 'package:screen_recorder_app/screens/region_selection_screen.dart';
import 'package:screen_recorder_app/services/file_save_service.dart';
import 'package:screen_recorder_app/services/screen_recorder.dart';
import 'package:screen_recorder_app/services/selector_backdrop.dart';
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
