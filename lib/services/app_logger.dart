import 'dart:developer' as developer;

/// Application logger. The UI never shows [error] stack traces.
class AppLogger {
  static const _name = 'screen_recorder';

  static void debug(String message) {
    developer.log(message, name: _name, level: 700);
  }

  static void info(String message) {
    developer.log(message, name: _name, level: 800);
  }

  static void warn(String message) {
    developer.log(message, name: _name, level: 900);
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
  }
}
