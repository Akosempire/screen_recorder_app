import 'dart:io';

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Native click-through overlay (Windows runner) that draws a halo around
/// the cursor and a ripple on each click. Because it is a real on-screen
/// layered window, gdigrab captures it, so the effect is both live and in
/// the recorded video.
class CursorOverlay {
  CursorOverlay({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'screen_recorder_app/windows';

  final MethodChannel _channel;
  bool _visible = false;

  bool get isSupported => Platform.isWindows;

  Future<void> show({bool halo = true, bool ripples = true}) async {
    if (!isSupported || _visible || (!halo && !ripples)) return;
    try {
      await _channel.invokeMethod<bool>('showCursorOverlay', {
        'halo': halo,
        'ripples': ripples,
      });
      _visible = true;
    } on MissingPluginException {
      AppLogger.debug('Cursor overlay not available in this build');
    } catch (error, stack) {
      AppLogger.warn('Cursor overlay show failed: $error\n$stack');
    }
  }

  Future<void> hide() async {
    if (!isSupported || !_visible) return;
    _visible = false;
    try {
      await _channel.invokeMethod<bool>('hideCursorOverlay');
    } on MissingPluginException {
      return;
    } catch (error, stack) {
      AppLogger.warn('Cursor overlay hide failed: $error\n$stack');
    }
  }
}
