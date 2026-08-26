import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Application logger. The UI never shows [error] stack traces.
class AppLogger {
  static const _name = 'screen_recorder';

  static void debug(String message) {
    developer.log(message, name: _name, level: 700);
  }

  static void info(String message) {
    developer.log(message, name: _name, level: 800);
    debugPrint('[screen_recorder] $message');
  }

  static void warn(String message) {
    developer.log(message, name: _name, level: 900);
    debugPrint('[screen_recorder] WARN $message');
  }

  static void error(
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    developer.log(
      message,
      name: _name,
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
    debugPrint('[screen_recorder] ERROR $message');
  }
}
