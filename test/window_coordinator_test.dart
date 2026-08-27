import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/models/display_server.dart';
import 'package:screen_recorder_app/models/screen_region.dart';
import 'package:screen_recorder_app/services/desktop_snapshot_service.dart';
import 'package:screen_recorder_app/services/native_window.dart';
import 'package:screen_recorder_app/services/selector_backdrop.dart';
import 'package:screen_recorder_app/services/window_coordinator.dart';

class _CountingSnapshots extends DesktopSnapshotService {
  _CountingSnapshots({
    List<File?>? captureResults,
    List<PortalCaptureResult>? portalResults,
  })  : _captureResults = List<File?>.from(captureResults ?? const []),
        _portalResults = List<PortalCaptureResult>.from(
          portalResults ?? const [],
        );

  final List<File?> _captureResults;
  final List<PortalCaptureResult> _portalResults;
  int captureCalls = 0;
  int portalCalls = 0;
  int get calls => captureCalls + portalCalls;
  final List<Duration> portalTimeouts = [];
  final List<String> portalParents = [];
  final List<List<String>> opsAtCapture = [];
  final List<List<String>> opsAtPortal = [];
  List<String> Function()? readOps;

  @override
  Future<File?> capture(
    DesktopGeometry geometry, {
    String parentWindow = '',
  }) async {
    captureCalls += 1;
    opsAtCapture.add(List<String>.from(readOps?.call() ?? const []));
    if (_captureResults.isEmpty) {
      return null;
    }
    return _captureResults.removeAt(0);
  }

  @override
  Future<PortalCaptureResult> capturePortal(
    DesktopGeometry geometry, {
    required String parentWindow,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    portalCalls += 1;
    portalTimeouts.add(timeout);
    portalParents.add(parentWindow);
    opsAtPortal.add(List<String>.from(readOps?.call() ?? const []));
    if (_portalResults.isEmpty) {
      return const PortalCaptureResult(PortalCaptureStatus.failed);
    }
    return _portalResults.removeAt(0);
  }
}

class _StubNativeWindow extends NativeWindowService {
  _StubNativeWindow([this.handle = 'wayland:test']);

  final String handle;

  @override
  Future<String> parentWindowHandle() async => handle;

  @override
  Future<AlphaProbe> probe() async => AlphaProbe.unavailable;
}

int _pngSeq = 0;

File _pngFile() {
  _pngSeq += 1;
  final file = File(
    '${Directory.systemTemp.path}/sr_coord_${DateTime.now().microsecondsSinceEpoch}_$_pngSeq.png',
  );
  file.writeAsBytesSync(List<int>.filled(80, 1));
  addTearDown(() {
    if (file.existsSync()) {
      file.deleteSync();
    }
  });
  return file;
}

PortalCaptureResult _ok([File? file]) {
  return PortalCaptureResult(PortalCaptureStatus.success, file ?? _pngFile());
}

const _x11Geometry = DesktopGeometry(
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

const _waylandGeometry = DesktopGeometry(
  displayServer: DisplayServer.wayland,
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

void expectInOrder(List<String> ops, List<String> sequence) {
  var from = 0;
  for (final item in sequence) {
    final index = ops.indexOf(item, from);
    expect(
      index,
      greaterThanOrEqualTo(0),
      reason: 'Expected "$item" after index $from in $ops',
    );
    from = index + 1;
  }
}

String lastOpacity(List<String> ops) {
  return ops.lastWhere((op) => op.startsWith('setOpacity'));
}

WindowCoordinator _x11Coordinator(_CountingSnapshots snapshots) {
  final coordinator = WindowCoordinator(
    snapshots: snapshots,
    nativeWindow: _StubNativeWindow('x11:0x1'),
    isGnomeDesktop: () => false,
  );
  snapshots.readOps = () => coordinator.windowOps;
  return coordinator;
}

WindowCoordinator _gnomeCoordinator(
  _CountingSnapshots snapshots, {
  String parent = 'wayland:handle',
  PortalTrust trust = PortalTrust.unknown,
}) {
  final coordinator = WindowCoordinator(
    snapshots: snapshots,
    nativeWindow: _StubNativeWindow(parent),
    isGnomeDesktop: () => true,
  );
  coordinator.portalTrust = trust;
  snapshots.readOps = () => coordinator.windowOps;
  return coordinator;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('live enterSelection never captures and never fades the window', () async {
    final snapshots = _CountingSnapshots();
    final coordinator = _x11Coordinator(snapshots);

    final snap = await coordinator.enterSelection(
      _x11Geometry,
      backdrop: SelectorBackdrop.liveHole,
    );

    expect(snap, isNull);
    expect(snapshots.calls, 0);
    expect(coordinator.windowOps.contains('setOpacity(0)'), isFalse);
    expectInOrder(coordinator.windowOps, [
      'setBackgroundColor(transparent)',
      'setOpacity(1)',
    ]);
  });

  test('X11 success fades then captures once, never portal', () async {
    final file = _pngFile();
    final snapshots = _CountingSnapshots(captureResults: [file]);
    final coordinator = _x11Coordinator(snapshots);

    final snap = await coordinator.enterSelection(
      _x11Geometry,
      backdrop: SelectorBackdrop.snapshot,
    );

    expect(snap, file);
    expect(snapshots.captureCalls, 1);
    expect(snapshots.portalCalls, 0);
    expect(lastOpacity(snapshots.opsAtCapture.single), 'setOpacity(0)');
    expectInOrder(snapshots.opsAtCapture.single, [
      'setOpacity(1)',
      'setOpacity(0)',
    ]);
    expect(lastOpacity(coordinator.windowOps), 'setOpacity(0)');
  });

  test('X11 first miss restores then captures once more', () async {
    final file = _pngFile();
    final snapshots = _CountingSnapshots(captureResults: [null, file]);
    final coordinator = _x11Coordinator(snapshots);

    final snap = await coordinator.enterSelection(
      _x11Geometry,
      backdrop: SelectorBackdrop.snapshot,
    );

    expect(snap, file);
    expect(snapshots.captureCalls, 2);
    expect(snapshots.portalCalls, 0);
    expect(lastOpacity(snapshots.opsAtCapture[0]), 'setOpacity(0)');
    expectInOrder(coordinator.windowOps, [
      'setOpacity(0)',
      'setOpacity(1)',
    ]);
    final between = snapshots.opsAtCapture[1]
        .sublist(snapshots.opsAtCapture[0].length);
    expect(between.contains('setOpacity(1)'), isTrue);
  });

  test('GNOME X11 uses capture, not the portal dance', () async {
    final file = _pngFile();
    final snapshots = _CountingSnapshots(captureResults: [file]);
    final coordinator = WindowCoordinator(
      snapshots: snapshots,
      nativeWindow: _StubNativeWindow('x11:0x1'),
      isGnomeDesktop: () => true,
    );
    snapshots.readOps = () => coordinator.windowOps;

    await coordinator.enterSelection(_x11Geometry);

    expect(snapshots.captureCalls, 1);
    expect(snapshots.portalCalls, 0);
    expect(lastOpacity(snapshots.opsAtCapture.single), 'setOpacity(0)');
  });

  test('GNOME unknown hide-first success is one still, no B', () async {
    final file = _pngFile();
    final snapshots = _CountingSnapshots(portalResults: [_ok(file)]);
    final coordinator = _gnomeCoordinator(snapshots);

    final snap = await coordinator.enterSelection(_waylandGeometry);

    expect(snap, file);
    expect(snapshots.portalCalls, 1);
    expect(snapshots.captureCalls, 0);
    expect(snapshots.portalTimeouts, [const Duration(seconds: 2)]);
    expect(lastOpacity(snapshots.opsAtPortal.single), 'setOpacity(0)');
    expect(coordinator.portalTrust, PortalTrust.trusted);
  });

  test('GNOME focused Deny does not retry and does not B', () async {
    final snapshots = _CountingSnapshots(
      portalResults: [
        const PortalCaptureResult(PortalCaptureStatus.cancelled),
      ],
    );
    final coordinator = _gnomeCoordinator(
      snapshots,
      trust: PortalTrust.untrusted,
    );

    final snap = await coordinator.enterSelection(_waylandGeometry);

    expect(snap, isNull);
    expect(snapshots.portalCalls, 1);
    expect(snapshots.captureCalls, 0);
    expect(snapshots.portalTimeouts, [const Duration(seconds: 45)]);
    expect(coordinator.portalTrust, PortalTrust.untrusted);
  });

  test('GNOME focused timeout retries once then stops', () async {
    final snapshots = _CountingSnapshots(
      portalResults: [
        const PortalCaptureResult(PortalCaptureStatus.timeout),
        const PortalCaptureResult(PortalCaptureStatus.timeout),
      ],
    );
    final coordinator = _gnomeCoordinator(
      snapshots,
      trust: PortalTrust.untrusted,
    );

    final snap = await coordinator.enterSelection(_waylandGeometry);

    expect(snap, isNull);
    expect(snapshots.portalCalls, 2);
    expect(snapshots.captureCalls, 0);
    expect(
      snapshots.portalTimeouts,
      [
        const Duration(seconds: 45),
        const Duration(seconds: 45),
      ],
    );
    expect(coordinator.portalTrust, PortalTrust.untrusted);
  });

  test('GNOME B runs only after a focused file, then next enter is hide-first',
      () async {
    final focused = _pngFile();
    final clean = _pngFile();
    final later = _pngFile();
    final snapshots = _CountingSnapshots(
      portalResults: [
        _ok(focused),
        _ok(clean),
        _ok(later),
      ],
    );
    final coordinator = _gnomeCoordinator(
      snapshots,
      trust: PortalTrust.untrusted,
    );

    final first = await coordinator.enterSelection(_waylandGeometry);
    expect(first, clean);
    expect(snapshots.portalCalls, 2);
    expect(snapshots.captureCalls, 0);
    expect(
      snapshots.portalTimeouts,
      [const Duration(seconds: 45), const Duration(seconds: 2)],
    );
    expect(lastOpacity(snapshots.opsAtPortal[0]), 'setOpacity(1)');
    expect(lastOpacity(snapshots.opsAtPortal[1]), 'setOpacity(0)');
    expect(coordinator.portalTrust, PortalTrust.trusted);

    final opsAfterFirst = List<String>.from(coordinator.windowOps);
    final second = await coordinator.enterSelection(_waylandGeometry);
    expect(second, later);
    expect(snapshots.portalCalls, 3);
    expect(snapshots.captureCalls, 0);
    expect(snapshots.portalTimeouts.last, const Duration(seconds: 2));
    final duringSecond =
        snapshots.opsAtPortal[2].sublist(opsAfterFirst.length);
    expect(lastOpacity(duringSecond), 'setOpacity(0)');
    expectInOrder(duringSecond, [
      'setOpacity(1)',
      'setOpacity(0)',
    ]);
    final fadeAt = duringSecond.indexOf('setOpacity(0)');
    expect(duringSecond.sublist(fadeAt + 1).contains('setOpacity(1)'), isFalse);
  });

  test('GNOME focused success with B miss stays untrusted', () async {
    final dirty = _pngFile();
    final snapshots = _CountingSnapshots(
      portalResults: [
        _ok(dirty),
        const PortalCaptureResult(PortalCaptureStatus.cancelled),
        _ok(_pngFile()),
      ],
    );
    final coordinator = _gnomeCoordinator(
      snapshots,
      trust: PortalTrust.untrusted,
    );

    final first = await coordinator.enterSelection(_waylandGeometry);
    expect(first, dirty);
    expect(snapshots.portalCalls, 2);
    expect(coordinator.portalTrust, PortalTrust.untrusted);

    await coordinator.enterSelection(_waylandGeometry);
    expect(snapshots.portalCalls, 4);
    expect(snapshots.portalTimeouts[2], const Duration(seconds: 45));
    expect(coordinator.portalTrust, isNot(PortalTrust.trusted));
  });

  test('GNOME hide-first miss restores opacity before focused', () async {
    final snapshots = _CountingSnapshots(
      portalResults: [
        const PortalCaptureResult(PortalCaptureStatus.cancelled),
        const PortalCaptureResult(PortalCaptureStatus.cancelled),
      ],
    );
    final coordinator = _gnomeCoordinator(
      snapshots,
      trust: PortalTrust.trusted,
    );

    await coordinator.enterSelection(_waylandGeometry);

    expect(snapshots.portalCalls, 2);
    expect(snapshots.captureCalls, 0);
    expect(
      snapshots.portalTimeouts,
      [const Duration(seconds: 2), const Duration(seconds: 45)],
    );
    expect(lastOpacity(snapshots.opsAtPortal[0]), 'setOpacity(0)');
    final between = snapshots.opsAtPortal[1]
        .sublist(snapshots.opsAtPortal[0].length);
    expect(between.contains('setOpacity(1)'), isTrue);
    expect(coordinator.portalTrust, PortalTrust.untrusted);
  });

  test('GNOME hide-first timeout does not mark untrusted', () async {
    final snapshots = _CountingSnapshots(
      portalResults: [
        const PortalCaptureResult(PortalCaptureStatus.timeout),
        const PortalCaptureResult(PortalCaptureStatus.cancelled),
      ],
    );
    final coordinator = _gnomeCoordinator(
      snapshots,
      trust: PortalTrust.trusted,
    );

    await coordinator.enterSelection(_waylandGeometry);

    expect(snapshots.portalCalls, 2);
    expect(coordinator.portalTrust, PortalTrust.trusted);
  });

  test('empty parent skips hide-first even when trusted', () async {
    final snapshots = _CountingSnapshots(
      portalResults: [
        const PortalCaptureResult(PortalCaptureStatus.cancelled),
      ],
    );
    final coordinator = _gnomeCoordinator(
      snapshots,
      parent: '',
      trust: PortalTrust.trusted,
    );

    await coordinator.enterSelection(_waylandGeometry);

    expect(snapshots.portalCalls, 1);
    expect(snapshots.captureCalls, 0);
    expect(snapshots.portalTimeouts, [const Duration(seconds: 45)]);
    expect(lastOpacity(snapshots.opsAtPortal.single), 'setOpacity(1)');
  });

  test('GNOME Wayland never uses kitchen-sink capture()', () async {
    final snapshots = _CountingSnapshots(
      portalResults: [_ok()],
    );
    final coordinator = _gnomeCoordinator(snapshots);

    await coordinator.enterSelection(_waylandGeometry);

    expect(snapshots.captureCalls, 0);
    expect(snapshots.portalCalls, greaterThan(0));
  });

  test('showHome restores an opaque window background', () async {
    final coordinator = _x11Coordinator(_CountingSnapshots());
    await coordinator.enterSelection(
      _x11Geometry,
      backdrop: SelectorBackdrop.liveHole,
    );
    await coordinator.showHome();

    expect(coordinator.windowOps.contains('setBackgroundColor(opaque)'), isTrue);
    expect(coordinator.windowOps.contains('clearOpaqueRegion'), isTrue);
    expect(
      coordinator.windowOps.lastWhere((op) => op.startsWith('setBackgroundColor')),
      'setBackgroundColor(opaque)',
    );
  });

  test('prepareRecordingChrome shrinks at opacity 0 and does not hide the GTK window',
      () async {
    final coordinator = _x11Coordinator(_CountingSnapshots());
    await coordinator.prepareRecordingChrome();

    expect(coordinator.windowOps.contains('setBackgroundColor(opaque)'), isTrue);
    expect(coordinator.windowOps.contains('clearOpaqueRegion'), isTrue);
    expect(
      coordinator.windowOps.contains('setBackgroundColor(transparent)'),
      isFalse,
    );
    expectInOrder(coordinator.windowOps, [
      'setAlwaysOnTop(false)',
      'setOpacity(0)',
      'setFullScreen(false)',
      'setResizable(true)',
      'setFixedBounds(recording)',
      'setBounds(recording)',
      'setResizable(false)',
    ]);
    expect(coordinator.windowOps.contains('hide'), isFalse);
    expect(coordinator.windowOps.contains('show'), isFalse);
    expect(coordinator.windowOps.contains('setAlwaysOnTop(true)'), isFalse);
  });

  test('showRecordingControls reapplies chip bounds after show', () async {
    final coordinator = _x11Coordinator(_CountingSnapshots());
    await coordinator.showRecordingControls(
      captureRegion: const ScreenRegion(x: 400, y: 400, width: 400, height: 400),
      geometry: _x11Geometry,
    );

    expectInOrder(coordinator.windowOps, [
      'setResizable(true)',
      'setFixedBounds(recording)',
      'setBounds(recording)',
      'setAlwaysOnTop(true)',
      'show',
      'setFixedBounds(recording)',
      'setResizable(false)',
    ]);
  });

  test('revealSelector fades the overlay in after enter stays hidden', () async {
    final snapshots = _CountingSnapshots(captureResults: [_pngFile()]);
    final coordinator = _x11Coordinator(snapshots);

    await coordinator.enterSelection(_x11Geometry);
    expect(lastOpacity(coordinator.windowOps), 'setOpacity(0)');

    await coordinator.revealSelector();
    expectInOrder(coordinator.windowOps, [
      'setOpacity(0)',
      'setOpacity(1)',
      'show',
      'focus',
    ]);
  });
}
