import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/models/display_server.dart';
import 'package:screen_recorder_app/services/desktop_snapshot_service.dart';
import 'package:screen_recorder_app/services/ffmpeg_process_manager.dart';
import 'package:screen_recorder_app/services/linux_desktop.dart';
import 'package:screen_recorder_app/services/xdg_portal_screenshot.dart';

void main() {
  test('portal request path strips unique-name punctuation', () {
    expect(
      portalRequestObjectPath(uniqueName: ':1.42', handleToken: 'sr1'),
      '/org/freedesktop/portal/desktop/request/1_42/sr1',
    );
  });

  test('portal uri parser accepts file URIs and plain paths', () {
    expect(
      filePathFromPortalUri('file:///tmp/shot.png'),
      '/tmp/shot.png',
    );
    expect(filePathFromPortalUri('/tmp/shot.png'), '/tmp/shot.png');
    expect(filePathFromPortalUri('https://example.test/x'), isNull);
    expect(filePathFromPortalUri(null), isNull);
  });

  test('portal Response uint32 maps to capture status', () {
    expect(portalStatusFromResponseCode(0), PortalCaptureStatus.success);
    expect(portalStatusFromResponseCode(1), PortalCaptureStatus.cancelled);
    expect(portalStatusFromResponseCode(2), PortalCaptureStatus.failed);
    expect(portalStatusFromResponseCode(99), PortalCaptureStatus.failed);
  });

  test('Response on a different request object does not complete the wait',
      () async {
    final predicted = DBusObjectPath(
      '/org/freedesktop/portal/desktop/request/1_42/sr1',
    );
    final other = DBusObjectPath(
      '/org/freedesktop/portal/desktop/request/1_42/other',
    );
    final waiter = PortalRequestWaiter(predictedPath: predicted);

    waiter.onSignal(_response(other, 1));
    expect(waiter.isCompleted, isFalse);

    waiter.onSignal(_response(predicted, 0));
    expect(waiter.isCompleted, isTrue);
    expect((await waiter.future).path, predicted);
  });

  test('Response matches the object path returned by Screenshot', () async {
    final predicted = DBusObjectPath(
      '/org/freedesktop/portal/desktop/request/1_42/sr1',
    );
    final returned = DBusObjectPath(
      '/org/freedesktop/portal/desktop/request/1_42/actual',
    );
    final waiter = PortalRequestWaiter(predictedPath: predicted);

    waiter.onSignal(_response(returned, 0));
    expect(waiter.isCompleted, isFalse);

    waiter.setReturnedHandle(returned);
    expect(waiter.isCompleted, isTrue);
    expect((await waiter.future).path, returned);
  });

  test('timeout still calls Close once', () async {
    final waiter = PortalRequestWaiter(
      predictedPath: DBusObjectPath(
        '/org/freedesktop/portal/desktop/request/1_42/sr1',
      ),
    );
    var closes = 0;
    final result = await waiter.waitForResult(
      timeout: const Duration(milliseconds: 20),
      closeOnTimeout: () async {
        closes += 1;
      },
      mapResponse: (_) async =>
          const PortalCaptureResult(PortalCaptureStatus.success),
    );
    expect(result.status, PortalCaptureStatus.timeout);
    expect(closes, 1);
  });

  test('cancelled Response does not Close', () async {
    final path = DBusObjectPath(
      '/org/freedesktop/portal/desktop/request/1_42/sr1',
    );
    final waiter = PortalRequestWaiter(predictedPath: path);
    waiter.onSignal(_response(path, 1));
    var closes = 0;
    final result = await waiter.waitForResult(
      timeout: const Duration(seconds: 1),
      closeOnTimeout: () async {
        closes += 1;
      },
      mapResponse: (signal) async => PortalCaptureResult(
        portalStatusFromResponseCode(signal.values[0].asUint32()),
      ),
    );
    expect(result.status, PortalCaptureStatus.cancelled);
    expect(closes, 0);
  });

  test('GNOME Wayland uses the screenshot portal when it returns a file',
      () async {
    final service = DesktopSnapshotService(
      runner: _FakeRunner({}),
      isGnomeDesktop: () => true,
      portalCapture: (file, {parentWindow = '', timeout = const Duration(seconds: 45)}) async {
        await file.writeAsBytes(List<int>.filled(80, 7));
        return PortalCaptureResult(PortalCaptureStatus.success, file);
      },
    );

    final snap = await service.capture(_waylandGeometry);
    expect(snap, isNotNull);
    expect(await snap!.length(), 80);
    await snap.delete();
  });

  test('wlroots Wayland uses grim before the portal', () async {
    var portalCalled = false;
    final service = DesktopSnapshotService(
      runner: _FakeRunner({
        'grim': (arguments) async {
          await File(arguments.last).writeAsBytes(List<int>.filled(80, 3));
          return ProcessResult(1, 0, '', '');
        },
      }),
      isGnomeDesktop: () => false,
      portalCapture: (file, {parentWindow = '', timeout = const Duration(seconds: 45)}) async {
        portalCalled = true;
        return PortalCaptureResult(PortalCaptureStatus.success, file);
      },
    );

    final snap = await service.capture(_waylandGeometry);
    expect(portalCalled, isFalse);
    expect(snap, isNotNull);
    expect(await snap!.length(), 80);
    await snap.delete();
  });

  test('GNOME Wayland does not start a screencast for the selector snapshot',
      () async {
    var screencastCalls = 0;
    final service = DesktopSnapshotService(
      runner: _FakeRunner({
        'gdbus': (arguments) async {
          if (arguments.contains('org.gnome.Shell.Screencast.ScreencastArea')) {
            screencastCalls += 1;
          }
          return ProcessResult(1, 1, '(false,)\n', 'denied');
        },
        'gnome-screenshot': (_) async => ProcessResult(1, 1, '', 'fail'),
        'grim': (_) async => ProcessResult(1, 1, '', 'fail'),
      }),
      isGnomeDesktop: () => true,
      portalCapture: (_, {parentWindow = '', timeout = const Duration(seconds: 45)}) async =>
          const PortalCaptureResult(PortalCaptureStatus.cancelled),
    );

    final snap = await service.capture(_waylandGeometry);
    expect(snap, isNull);
    expect(screencastCalls, 0);
  });

  test('GNOME Wayland capturePortal never invokes gnome-screenshot or grim',
      () async {
    var gnomeScreenshot = 0;
    var grim = 0;
    var gdbus = 0;
    Duration? recordedTimeout;
    var recordedParent = '';
    final service = DesktopSnapshotService(
      runner: _FakeRunner({
        'gnome-screenshot': (_) async {
          gnomeScreenshot += 1;
          return ProcessResult(1, 1, '', 'fail');
        },
        'grim': (_) async {
          grim += 1;
          return ProcessResult(1, 1, '', 'fail');
        },
        'gdbus': (_) async {
          gdbus += 1;
          return ProcessResult(1, 1, '', 'fail');
        },
      }),
      isGnomeDesktop: () => true,
      portalCapture: (_, {parentWindow = '', timeout = const Duration(seconds: 45)}) async {
        recordedTimeout = timeout;
        recordedParent = parentWindow;
        return const PortalCaptureResult(PortalCaptureStatus.cancelled);
      },
    );

    final result = await service.capturePortal(
      _waylandGeometry,
      parentWindow: 'wayland:1',
      timeout: const Duration(seconds: 2),
    );

    expect(result.status, PortalCaptureStatus.cancelled);
    expect(result.hasFile, isFalse);
    expect(gnomeScreenshot, 0);
    expect(grim, 0);
    expect(gdbus, 0);
    expect(recordedTimeout, const Duration(seconds: 2));
    expect(recordedParent, 'wayland:1');
  });
}

DBusSignal _response(DBusObjectPath path, int code) {
  return DBusSignal(
    sender: ':1.42',
    path: path,
    interface: 'org.freedesktop.portal.Request',
    name: 'Response',
    values: [
      DBusUint32(code),
      DBusDict.stringVariant({}),
    ],
  );
}

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

class _FakeRunner extends ProcessRunner {
  _FakeRunner(this.handlers);

  final Map<String, Future<ProcessResult> Function(List<String> arguments)>
      handlers;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
  }) {
    final handler = handlers[executable];
    if (handler == null) {
      throw ProcessException(executable, arguments, 'not faked');
    }
    return handler(arguments);
  }
}
