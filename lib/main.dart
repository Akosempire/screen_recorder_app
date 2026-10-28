import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'mobile/mobile_app.dart';
import 'services/demo_mode.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    // Phones and tablets: their own simple recorder screen.
    runApp(const MobileApp());
    return;
  }
  MediaKit.ensureInitialized(); // video playback in the editor
  DemoMode.parse(args);

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1180, 760),
    minimumSize: Size(860, 600),
    center: true,
    title: 'Screen Recorder',
    backgroundColor: Color(0xFFF2F2F3),
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setTitle('Screen Recorder');
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const ScreenRecorderApp());
}


