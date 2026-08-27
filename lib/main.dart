import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(460, 420),
    minimumSize: Size(400, 360),
    center: true,
    title: 'Screen Recorder',
    backgroundColor: Color(0xFF121418),
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setTitle('Screen Recorder');
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const ScreenRecorderApp());
}


