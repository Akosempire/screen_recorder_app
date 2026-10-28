import 'dart:io';

import 'app_logger.dart';

/// Where "Buy me suya" sends people.
const supportUrl = 'https://buymeamalt.com/@ibrahim_designer';

/// Opens [supportUrl] in the default browser.
Future<void> openSupportPage() => openUrl(supportUrl);

/// Opens [url] in the default browser. Only http(s) links are opened.
Future<bool> openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return false;
  try {
    if (Platform.isWindows) {
      // Not `cmd /c start`: cmd treats & in query strings as a command separator.
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [url]);
    } else {
      await Process.start('xdg-open', [url]);
    }
    return true;
  } catch (error) {
    AppLogger.warn('Could not open $url: $error');
    return false;
  }
}
