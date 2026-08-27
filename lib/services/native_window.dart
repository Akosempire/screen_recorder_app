import 'package:flutter/services.dart';

import '../models/display_server.dart';
import 'app_logger.dart';
import 'selector_backdrop.dart';

/// GTK window helpers: compositor probe and opaque-region updates.
///
/// Input region stays the full window. Only the opaque region shrinks to
/// chrome so the hole and dim can composite.
class NativeWindowService {
  NativeWindowService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'screen_recorder_app/native_window';

  final MethodChannel _channel;
  AlphaProbe? _cached;
  Future<AlphaProbe>? _inFlight;

  /// Cached at process start. Do not start this from Start Recording —
  /// portal timing and window mapping already fight you there.
  Future<AlphaProbe> probe() {
    if (_cached != null) {
      return Future<AlphaProbe>.value(_cached);
    }
    return _inFlight ??= _probeOnce();
  }

  Future<AlphaProbe> _probeOnce() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'getCapabilities',
      );
      final probe = _parse(raw);
      _cached = probe;
      AppLogger.info(
        'Native alpha probe: display=${probe.nativeDisplayServer} '
        'composited=${probe.composited} rgba=${probe.hasRgbaVisual} '
        'opaqueRegion=${probe.opaqueRegionSupported} passed=${probe.passed}',
      );
      return probe;
    } on MissingPluginException {
      _cached = AlphaProbe.unavailable;
      return _cached!;
    } catch (error, stack) {
      AppLogger.debug('Native alpha probe failed: $error\n$stack');
      _cached = AlphaProbe.unavailable;
      return _cached!;
    }
  }

  Future<void> setOpaqueRegion(List<Rect> rects) async {
    try {
      await _channel.invokeMethod<bool>('setOpaqueRegion', {
        'rects': [
          for (final rect in rects)
            {
              'x': rect.left.round(),
              'y': rect.top.round(),
              'width': rect.width.round(),
              'height': rect.height.round(),
            },
        ],
      });
    } on MissingPluginException {
      return;
    } catch (error, stack) {
      AppLogger.debug('setOpaqueRegion failed: $error\n$stack');
    }
  }

  Future<void> clearOpaqueRegion() async {
    try {
      await _channel.invokeMethod<bool>('clearOpaqueRegion');
    } on MissingPluginException {
      return;
    } catch (error, stack) {
      AppLogger.debug('clearOpaqueRegion failed: $error\n$stack');
    }
  }

  /// Pin the GTK window to [bounds]. window_manager setSize is ignored on
  /// GNOME Wayland after fullscreen; geometry hints are not.
  Future<void> setFixedBounds(Rect bounds) async {
    try {
      await _channel.invokeMethod<bool>('setFixedBounds', {
        'x': bounds.left.round(),
        'y': bounds.top.round(),
        'width': bounds.width.round().clamp(1, 10000),
        'height': bounds.height.round().clamp(1, 10000),
      });
    } on MissingPluginException {
      return;
    } catch (error, stack) {
      AppLogger.debug('setFixedBounds failed: $error\n$stack');
    }
  }

  /// Drop min=max size hints so the home and selector windows can resize.
  Future<void> clearFixedBounds() async {
    try {
      await _channel.invokeMethod<bool>('clearFixedBounds');
    } on MissingPluginException {
      return;
    } catch (error, stack) {
      AppLogger.debug('clearFixedBounds failed: $error\n$stack');
    }
  }

  /// Portal `parent_window` token (`wayland:…` or `x11:0x…`). Empty if unknown.
  Future<String> parentWindowHandle() async {
    try {
      for (var i = 0; i < 8; i++) {
        final raw = await _channel.invokeMethod<String>('getParentWindow');
        if (raw != null && raw.isNotEmpty) {
          return raw;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } on MissingPluginException {
      return '';
    } catch (error, stack) {
      AppLogger.debug('getParentWindow failed: $error\n$stack');
    }
    return '';
  }

  static AlphaProbe _parse(Map<String, dynamic>? raw) {
    if (raw == null) {
      return AlphaProbe.unavailable;
    }
    final serverName = raw['displayServer'] as String?;
    DisplayServer? server;
    switch (serverName) {
      case 'x11':
        server = DisplayServer.x11;
      case 'wayland':
        server = DisplayServer.wayland;
      case 'unknown':
        server = DisplayServer.unknown;
    }
    final composited = raw['composited'] == true;
    final hasRgba = raw['hasRgbaVisual'] == true;
    final opaque = raw['opaqueRegionSupported'] == true;
    final probePassed = raw['probePassed'] == true;
    return AlphaProbe(
      composited: composited,
      hasRgbaVisual: hasRgba,
      opaqueRegionSupported: opaque,
      nativeDisplayServer: server,
      glHasAlpha: raw['glHasAlpha'] == true,
      probePassed: probePassed,
    );
  }
}
