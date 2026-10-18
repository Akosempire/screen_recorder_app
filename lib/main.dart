import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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


