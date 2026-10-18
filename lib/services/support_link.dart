import 'dart:io';

import 'app_logger.dart';

/// Where "Buy me suya" sends people.
const supportUrl = 'https://buymeamalt.com/@ibrahim_designer';

/// Opens [supportUrl] in the default browser.
Future<void> openSupportPage() async {
  try {
    if (Platform.isWindows) {
      // `start` via cmd opens the URL with the default browser.
      await Process.start('cmd', ['/c', 'start', '', supportUrl]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [supportUrl]);
    } else {
      await Process.start('xdg-open', [supportUrl]);
    }
  } catch (error) {
    AppLogger.warn('Could not open $supportUrl: $error');
  }
}
