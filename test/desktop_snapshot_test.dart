import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/models/display_server.dart';
import 'package:screen_recorder_app/services/desktop_snapshot_service.dart';
import 'package:screen_recorder_app/services/ffmpeg_process_manager.dart';
import 'package:screen_recorder_app/services/linux_desktop.dart';

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

  test('GNOME Wayland uses the screenshot portal when it returns a file', () async {
    final service = DesktopSnapshotService(
      runner: _FakeRunner({}),
      isGnomeDesktop: () => true,
      portalCapture: (file) async {
        await file.writeAsBytes(List<int>.filled(80, 7));
        return file;
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
      portalCapture: (file) async {
        portalCalled = true;
        return file;
      },
    );

    final snap = await service.capture(_waylandGeometry);
    expect(portalCalled, isFalse);
    expect(snap, isNotNull);
    expect(await snap!.length(), 80);
    await snap.delete();
  });

  test('GNOME Wayland does not start a screencast for the selector snapshot', () async {
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
      portalCapture: (_) async => null,
    );

    final snap = await service.capture(_waylandGeometry);
    expect(snap, isNull);
    expect(screencastCalls, 0);
  });
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
