import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/models/display_server.dart';
import 'package:screen_recorder_app/services/native_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'screen_recorder_app/native_window';

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
  });

  test('probe is cached at first call, not repeated', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
      expect(call.method, 'getCapabilities');
      calls += 1;
      return {
        'displayServer': 'x11',
        'composited': true,
        'hasRgbaVisual': true,
        'glHasAlpha': false,
        'opaqueRegionSupported': true,
        'probePassed': true,
      };
    });

    final service = NativeWindowService(
      channel: const MethodChannel(channelName),
    );
    final first = await service.probe();
    final second = await service.probe();

    expect(calls, 1);
    expect(first.passed, isTrue);
    expect(first.nativeDisplayServer, DisplayServer.x11);
    expect(second.passed, isTrue);
  });

  test('missing plugin is a failed probe, not a throw', () async {
    final service = NativeWindowService(
      channel: const MethodChannel('screen_recorder_app/missing'),
    );
    final probe = await service.probe();
    expect(probe.passed, isFalse);
    expect(probe.opaqueRegionSupported, isFalse);
  });
}
