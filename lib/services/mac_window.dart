import 'dart:io';

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// macOS window helpers (Swift side in macos/Runner/MainFlutterWindow.swift).
///
/// The region selector must cover the whole main display, menu bar
/// included, without going fullscreen (which opens a new Space). The native
/// side raises the window above the menu bar and stops macOS from pushing
/// it below it.
class MacWindow {
  static const _channel = MethodChannel('screen_recorder_app/macos');

  static Future<void> enterOverlay() => _invoke('enterOverlay');

  static Future<void> exitOverlay() => _invoke('exitOverlay');

  static Future<void> _invoke(String method) async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      return;
    } catch (error) {
      AppLogger.debug('MacWindow.$method failed: $error');
    }
  }
}
