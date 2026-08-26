import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/models/display_server.dart';
import 'package:screen_recorder_app/services/desktop_snapshot_service.dart';
import 'package:screen_recorder_app/services/selector_backdrop.dart';
import 'package:screen_recorder_app/services/window_coordinator.dart';

class _CountingSnapshots extends DesktopSnapshotService {
  int calls = 0;
  File? result;

  @override
  Future<File?> capture(
    DesktopGeometry geometry, {
    String parentWindow = '',
  }) async {
    calls += 1;
    return result;
  }
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('live enterSelection never captures and never fades the window', () async {
    final snapshots = _CountingSnapshots();
    final coordinator = WindowCoordinator(snapshots: snapshots);

    final snap = await coordinator.enterSelection(
      _geometry,
      backdrop: SelectorBackdrop.liveHole,
    );

    expect(snap, isNull);
    expect(snapshots.calls, 0);
    expect(coordinator.windowOps, isNot(contains('setOpacity(0)')));
    expect(coordinator.windowOps, contains('setBackgroundColor(transparent)'));
    expect(coordinator.windowOps, contains('setOpacity(1)'));
  });

  test('snapshot enterSelection captures without fading first', () async {
    final snapshots = _CountingSnapshots();
    final coordinator = WindowCoordinator(snapshots: snapshots);

    await coordinator.enterSelection(
      _geometry,
      backdrop: SelectorBackdrop.snapshot,
    );

    expect(snapshots.calls, greaterThan(0));
    expect(coordinator.windowOps, isNot(contains('setOpacity(0)')));
    expect(coordinator.windowOps, contains('setBackgroundColor(opaque)'));
  });

  test('snapshot enterSelection fades only after a still succeeds', () async {
    final file = File(
      '${Directory.systemTemp.path}/sr_coord_snap_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(List<int>.filled(80, 1));
    addTearDown(() {
      if (file.existsSync()) {
        file.deleteSync();
      }
    });
    final snapshots = _CountingSnapshots()..result = file;
    final coordinator = WindowCoordinator(snapshots: snapshots);

    await coordinator.enterSelection(
      _geometry,
      backdrop: SelectorBackdrop.snapshot,
    );

    expect(snapshots.calls, greaterThan(1));
    expect(coordinator.windowOps, contains('setOpacity(0)'));
  });

  test('showHome restores an opaque window background', () async {
    final coordinator = WindowCoordinator(snapshots: _CountingSnapshots());
    await coordinator.enterSelection(
      _geometry,
      backdrop: SelectorBackdrop.liveHole,
    );
    await coordinator.showHome();

    expect(coordinator.windowOps, contains('setBackgroundColor(opaque)'));
    expect(coordinator.windowOps, contains('clearOpaqueRegion'));
    expect(
      coordinator.windowOps.lastWhere((op) => op.startsWith('setBackgroundColor')),
      'setBackgroundColor(opaque)',
    );
  });

  test('prepareRecordingChrome restores opaque chrome before the chip shows',
      () async {
    final coordinator = WindowCoordinator(snapshots: _CountingSnapshots());
    await coordinator.prepareRecordingChrome();

    expect(coordinator.windowOps, contains('setBackgroundColor(opaque)'));
    expect(coordinator.windowOps, contains('clearOpaqueRegion'));
    expect(coordinator.windowOps, isNot(contains('setBackgroundColor(transparent)')));
  });
}
