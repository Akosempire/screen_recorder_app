import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';
import 'cursor_overlay.dart';
import 'recording_options.dart';

/// Drives the native face-camera bubble (Windows runner): a draggable,
/// always-on-top webcam circle that is recorded along with the screen.
///
/// Follows [RecordingOptions]: turning the camera on shows the bubble right
/// away so it can be positioned before recording.
class CameraBubbleService extends ChangeNotifier {
  CameraBubbleService._({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(CursorOverlay.channelName) {
    _options.addListener(_sync);
  }

  static final CameraBubbleService instance = CameraBubbleService._();

  final MethodChannel _channel;
  RecordingOptions get _options => RecordingOptions.instance;

  List<String> _devices = const [];
  String? _error;
  bool _visible = false;
  bool _busy = false;
  _Applied? _applied;

  bool get isSupported => Platform.isWindows;
  List<String> get devices => _devices;
  String? get error => _error;
  bool get visible => _visible;

  Future<void> refreshDevices() async {
    if (!isSupported) return;
    try {
      final list = await _channel.invokeListMethod<String>('listCameras');
      _devices = List.unmodifiable(list ?? const []);
      notifyListeners();
    } on MissingPluginException {
      return;
    } catch (error) {
      AppLogger.debug('listCameras failed: $error');
    }
  }

  /// Snaps the bubble to [corner] (and remembers the choice). The user can
  /// also drag the bubble anywhere with the mouse.
  Future<void> moveTo(CameraCorner corner) async {
    _options.cameraCorner = corner;
    if (!isSupported || !_visible) return;
    try {
      await _channel.invokeMethod<bool>('moveCamera', corner.index);
    } on MissingPluginException {
      return;
    } catch (error) {
      AppLogger.debug('moveCamera failed: $error');
    }
  }

  /// Re-shows the bubble on top (e.g. after the selector overlay closed).
  Future<void> bringToFront() async {
    if (_options.cameraOn) {
      _applied = null;
      await _sync();
    }
  }

  Future<void> _sync() async {
    if (!isSupported || _busy) return;
    final wanted = _options.cameraOn
        ? _Applied(
            _options.cameraSize.diameter,
            _options.cameraCircle,
            _options.cameraDevice ?? '',
            _options.cameraFlip,
          )
        : null;
    if (wanted == _applied && (wanted != null) == _visible) return;
    _busy = true;
    try {
      if (wanted == null) {
        await _channel.invokeMethod<bool>('hideCamera');
        _visible = false;
        _error = null;
      } else {
        final error = await _channel.invokeMethod<String?>('showCamera', {
          'diameter': wanted.diameter,
          'circle': wanted.circle,
          'flip': wanted.flip,
          'device': wanted.device,
          'corner': _options.cameraCorner.index,
        });
        if (error != null && error.isNotEmpty) {
          _error = error;
          _visible = false;
          _applied = null;
          _busy = false;
          notifyListeners();
          _options.cameraOn = false;
          return;
        }
        _error = null;
        _visible = true;
      }
      _applied = wanted;
    } on MissingPluginException {
      _error = 'The camera is not available in this build.';
    } catch (error) {
      AppLogger.warn('Camera bubble failed: $error');
      _error = 'Could not start the camera.';
    } finally {
      _busy = false;
    }
    notifyListeners();
    // Options may have changed while the call was in flight.
    final latest = _options.cameraOn
        ? _Applied(
            _options.cameraSize.diameter,
            _options.cameraCircle,
            _options.cameraDevice ?? '',
            _options.cameraFlip,
          )
        : null;
    if (latest != _applied) await _sync();
  }
}

@immutable
class _Applied {
  const _Applied(this.diameter, this.circle, this.device, this.flip);

  final int diameter;
  final bool circle;
  final String device;
  final bool flip;

  @override
  bool operator ==(Object other) =>
      other is _Applied &&
      other.diameter == diameter &&
      other.circle == circle &&
      other.device == device &&
      other.flip == flip;

  @override
  int get hashCode => Object.hash(diameter, circle, device, flip);
}
