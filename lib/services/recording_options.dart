import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// User-facing capture effects. Persisted to a small JSON file so the
/// choices survive restarts.
class RecordingOptions extends ChangeNotifier {
  RecordingOptions._();

  static final RecordingOptions instance = RecordingOptions._();

  /// Live halo around the cursor plus a ripple on every click. On Windows it
  /// is a click-through on-screen overlay, so it shows up live and is also
  /// captured into the video.
  bool _cursorHighlight = true;

  /// After recording, zoom the video in around clicks and pan to follow the
  /// mouse, then zoom back out when the cursor goes idle.
  bool _autoZoom = true;

  /// Maximum zoom factor used by auto-zoom (1.2 – 3.0).
  double _zoomLevel = 1.8;

  bool _loaded = false;

  bool get cursorHighlight => _cursorHighlight;
  bool get autoZoom => _autoZoom;
  double get zoomLevel => _zoomLevel;

  /// Effects are implemented for the Windows backend.
  static bool get effectsSupported => Platform.isWindows;

  set cursorHighlight(bool value) {
    if (_cursorHighlight == value) return;
    _cursorHighlight = value;
    _changed();
  }

  set autoZoom(bool value) {
    if (_autoZoom == value) return;
    _autoZoom = value;
    _changed();
  }

  set zoomLevel(double value) {
    final clamped = value.clamp(1.2, 3.0).toDouble();
    if (_zoomLevel == clamped) return;
    _zoomLevel = clamped;
    _changed();
  }

  void _changed() {
    notifyListeners();
    _save();
  }

  static File? get _file {
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']
        : (Platform.environment['XDG_CONFIG_HOME'] ??
            (Platform.environment['HOME'] == null
                ? null
                : p.join(Platform.environment['HOME']!, '.config')));
    if (base == null || base.isEmpty) return null;
    return File(p.join(base, 'screen_recorder_app', 'options.json'));
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = _file;
      if (file == null || !await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return;
      _cursorHighlight = data['cursorHighlight'] as bool? ?? _cursorHighlight;
      _autoZoom = data['autoZoom'] as bool? ?? _autoZoom;
      final zoom = data['zoomLevel'];
      if (zoom is num) _zoomLevel = zoom.toDouble().clamp(1.2, 3.0);
      notifyListeners();
    } catch (_) {
      // Corrupt or unreadable preferences fall back to defaults.
    }
  }

  Future<void> _save() async {
    try {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'cursorHighlight': _cursorHighlight,
        'autoZoom': _autoZoom,
        'zoomLevel': _zoomLevel,
      }));
    } catch (_) {}
  }
}
