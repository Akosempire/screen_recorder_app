import 'dart:io';

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Opens [url] in the default browser. Only http(s) links are opened.
Future<bool> openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return false;
  try {
    if (Platform.isAndroid) {
      return await const MethodChannel('screen_recorder_app/android').invokeMethod<bool>('openUrl', url) ?? false;
    }
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
