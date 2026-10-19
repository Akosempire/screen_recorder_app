import 'dart:io';

import '../models/display_server.dart';
import 'linux_screen_service.dart';
import 'mac_screen_service.dart';
import 'windows_screen_service.dart';

/// Desktop layout for the current platform.
Future<DesktopGeometry> queryDesktopGeometry() {
  if (Platform.isWindows) {
    return const WindowsScreenService().queryGeometry();
  }
  if (Platform.isMacOS) {
    return const MacScreenService().queryGeometry();
  }
  return LinuxScreenService().queryGeometry();
}
