import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/mobile/android_recorder.dart';
import 'package:screen_recorder_app/mobile/mobile_app.dart';

void main() {
  const channel = MethodChannel('screen_recorder_app/android');
  final calls = <MethodCall>[];
  var recordings = <Map<String, Object?>>[];

  setUp(() {
    calls.clear();
    recordings = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'status':
          return {'recording': false, 'paused': false, 'elapsedMs': 0};
        case 'list':
          return recordings;
        case 'filesDir':
          return '/tmp';
        case 'thumbnail':
          return null;
        case 'start':
          return {'mic': true};
      }
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> emit(WidgetTester tester, String method, [Object? args]) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(channel.name, data, (_) {});
    await tester.pump();
  }

  testWidgets('phone screen: start, recording state, stop, saved list', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final recorder = AndroidRecorder();
    await tester.pumpWidget(MobileApp(recorder: recorder));
    await tester.pump();
    expect(find.text('Tap to record your screen'), findsOneWidget);
    expect(find.textContaining('Recordings you make appear here'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('record')));
    await tester.pump();
    final start = calls.lastWhere((c) => c.method == 'start');
    expect((start.arguments as Map)['mic'], isTrue);
    expect((start.arguments as Map)['maxSeconds'], 0, reason: 'no limit before payments are switched on');

    await emit(tester, 'started', {'width': 1080, 'height': 2340});
    expect(find.text('Recording'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(calls.any((c) => c.method == 'stop'), isTrue);

    recordings = [
      {'uri': 'content://media/external/video/media/1', 'name': 'Screen Recording 2026-10-28 21-40-12.mp4',
       'durationMs': 42000, 'size': 5 * 1024 * 1024, 'added': 1761680000000},
    ];
    await emit(tester, 'finished', {'uri': 'content://media/external/video/media/1', 'durationMs': 42000, 'limit': false});
    await tester.pump();
    expect(find.text('Tap to record your screen'), findsOneWidget);
    expect(find.text('Screen Recording 2026-10-28 21-40-12'), findsOneWidget);
    expect(find.text('0:42'), findsOneWidget);
    expect(find.textContaining('Saved to your Gallery'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    recorder.dispose();
  });

  testWidgets('errors from Android are shown', (tester) async {
    final recorder = AndroidRecorder();
    await tester.pumpWidget(MobileApp(recorder: recorder));
    await tester.pump();
    await emit(tester, 'error', {'message': 'Could not start recording: test'});
    await tester.pump();
    expect(find.text('Could not start recording: test'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    recorder.dispose();
  });
}
