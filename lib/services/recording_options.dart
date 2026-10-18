import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// How the live cursor overlay draws.
enum CursorStyle {
  haloAndRipples('Halo + ripples', 'A yellow halo follows the cursor and every click ripples.'),
  halo('Halo only', 'A soft yellow halo follows the cursor. Clicks are not marked.'),
  ripples('Ripples only', 'Only clicks are marked, with an expanding ring.'),
  off('Off', 'The normal cursor, with no highlight.');

  const CursorStyle(this.label, this.description);

  final String label;
  final String description;

  bool get drawsHalo => this == haloAndRipples || this == CursorStyle.halo;
  bool get drawsRipples => this == haloAndRipples || this == CursorStyle.ripples;
}

/// User-facing capture effects. Persisted to a small JSON file so the
/// choices survive restarts.
class RecordingOptions extends ChangeNotifier {
  RecordingOptions._();

  static final RecordingOptions instance = RecordingOptions._();

  CursorStyle _cursorStyle = CursorStyle.haloAndRipples;
  bool _autoZoom = true;
  double _zoomLevel = 1.8;
  double _holdSeconds = 2.6;
  double _smoothness = 4;
  bool _tourDone = false;
  bool _loaded = false;

  /// True once preferences have been read from disk (the app has booted).
  bool get loaded => _loaded;

  CursorStyle get cursorStyle => _cursorStyle;

  /// Live halo and/or click ripples. On Windows it is a click-through
  /// on-screen overlay, so it shows up live and is captured into the video.
  bool get cursorHighlight => _cursorStyle != CursorStyle.off;

  /// After recording, zoom in around clicks, pan with the mouse, and zoom
  /// back out when the cursor goes idle.
  bool get autoZoom => _autoZoom;

  /// Maximum zoom factor used by auto-zoom (1.2 – 3.0).
  double get zoomLevel => _zoomLevel;

  /// Seconds the camera stays zoomed after a click (1 – 5).
  double get holdSeconds => _holdSeconds;

  /// Camera smoothness, 1 (snappy) – 10 (very smooth).
  double get smoothness => _smoothness;

  /// Pan time constant derived from [smoothness].
  double get panTau => 0.12 + _smoothness * 0.04;

  bool get tourDone => _tourDone;

  /// Effects are implemented for the Windows backend.
  static bool get effectsSupported => Platform.isWindows;

  set cursorStyle(CursorStyle value) {
    if (_cursorStyle == value) return;
    _cursorStyle = value;
    _changed();
  }

  set cursorHighlight(bool value) {
    cursorStyle = value ? CursorStyle.haloAndRipples : CursorStyle.off;
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

  set holdSeconds(double value) {
    final clamped = value.clamp(1.0, 5.0).toDouble();
    if (_holdSeconds == clamped) return;
    _holdSeconds = clamped;
    _changed();
  }

  set smoothness(double value) {
    final clamped = value.clamp(1.0, 10.0).toDouble();
    if (_smoothness == clamped) return;
    _smoothness = clamped;
    _changed();
  }

  set tourDone(bool value) {
    if (_tourDone == value) return;
    _tourDone = value;
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
    try {
      final file = _file;
      if (file != null && await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is Map) {
          final style = data['cursorStyle'];
          if (style is String) {
            _cursorStyle = CursorStyle.values.firstWhere(
              (s) => s.name == style,
              orElse: () => _cursorStyle,
            );
          } else if (data['cursorHighlight'] == false) {
            _cursorStyle = CursorStyle.off;
          }
          _autoZoom = data['autoZoom'] as bool? ?? _autoZoom;
          final zoom = data['zoomLevel'];
          if (zoom is num) _zoomLevel = zoom.toDouble().clamp(1.2, 3.0);
          final hold = data['holdSeconds'];
          if (hold is num) _holdSeconds = hold.toDouble().clamp(1.0, 5.0);
          final smooth = data['smoothness'];
          if (smooth is num) _smoothness = smooth.toDouble().clamp(1.0, 10.0);
          _tourDone = data['tourDone'] as bool? ?? _tourDone;
        }
      }
    } catch (_) {
      // Corrupt or unreadable preferences fall back to defaults.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'cursorStyle': _cursorStyle.name,
        'autoZoom': _autoZoom,
        'zoomLevel': _zoomLevel,
        'holdSeconds': _holdSeconds,
        'smoothness': _smoothness,
        'tourDone': _tourDone,
      }));
    } catch (_) {}
  }
}
