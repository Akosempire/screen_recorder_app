import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Application logger. The UI never shows [error] stack traces.
class AppLogger {
  static const _name = 'screen_recorder';

  static final List<String> _recent = [];

  /// The last few hundred info / warning / error lines, oldest first, for
  /// "Get help" (only sent if the user agrees).
  static List<String> get recent => List.unmodifiable(_recent);

  static void _keep(String level, String message) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _recent.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)} $level $message');
    if (_recent.length > 300) _recent.removeRange(0, _recent.length - 300);
  }

  static void debug(String message) {
    developer.log(message, name: _name, level: 700);
  }

  static void info(String message) {
    developer.log(message, name: _name, level: 800);
    _keep('INFO', message);
    debugPrint('[screen_recorder] $message');
  }

  static void warn(String message) {
    developer.log(message, name: _name, level: 900);
    _keep('WARN', message);
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
    _keep('ERROR', error == null ? message : '$message: $error');
  }
}
