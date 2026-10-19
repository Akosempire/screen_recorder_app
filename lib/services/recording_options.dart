import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/cursor_input.dart' show liveEffectsSupported, platformCanTrackCursor;
import 'app_folders.dart';
import 'recording_background.dart';

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

/// Size of the face-camera bubble (logical diameter in pixels).
enum CameraSize {
  small('S', 160),
  medium('M', 220),
  large('L', 300);

  const CameraSize(this.label, this.diameter);

  final String label;
  final int diameter;
}

/// Where the face-camera bubble snaps to. Index matches the native side.
enum CameraCorner {
  topLeft('Top left'),
  topRight('Top right'),
  bottomLeft('Bottom left'),
  bottomRight('Bottom right');

  const CameraCorner(this.label);

  final String label;
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
  bool _cameraOn = false;
  CameraSize _cameraSize = CameraSize.medium;
  bool _cameraCircle = true;
  bool _cameraFlip = false;
  String? _cameraDevice;
  CameraCorner _cameraCorner = CameraCorner.bottomLeft;
  BackgroundSpec _background = const BackgroundSpec();
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

  /// Face-camera bubble on screen. Not persisted: the camera only turns on
  /// when the user asks for it in this session.
  bool get cameraOn => _cameraOn;
  CameraSize get cameraSize => _cameraSize;
  bool get cameraCircle => _cameraCircle;

  /// Show the camera picture the other way up (for cameras that report their
  /// orientation wrongly).
  bool get cameraFlip => _cameraFlip;

  set cameraFlip(bool value) {
    if (_cameraFlip == value) return;
    _cameraFlip = value;
    _changed();
  }

  /// Camera friendly name, or null for the first camera.
  String? get cameraDevice => _cameraDevice;

  CameraCorner get cameraCorner => _cameraCorner;

  set cameraCorner(CameraCorner value) {
    if (_cameraCorner == value) return;
    _cameraCorner = value;
    _changed();
  }

  set cameraOn(bool value) {
    if (_cameraOn == value) return;
    _cameraOn = value;
    notifyListeners();
  }

  set cameraSize(CameraSize value) {
    if (_cameraSize == value) return;
    _cameraSize = value;
    _changed();
  }

  set cameraCircle(bool value) {
    if (_cameraCircle == value) return;
    _cameraCircle = value;
    _changed();
  }

  set cameraDevice(String? value) {
    if (_cameraDevice == value) return;
    _cameraDevice = value;
    _changed();
  }

  /// Background behind the recording, applied when exporting (all platforms).
  BackgroundSpec get background => _background;

  /// Turns the background off, or picks a preset / uploaded image.
  void setBackgroundKind(BackgroundKind kind) => _setBackground(kind: kind);

  void setBackgroundPreset(BackgroundPreset preset) =>
      _setBackground(kind: BackgroundKind.preset, preset: preset);

  void setBackgroundImage(String path) =>
      _setBackground(kind: BackgroundKind.image, imagePath: path);

  set backgroundPadding(double value) => _setBackground(
      padding: value.clamp(BackgroundSpec.minPadding, BackgroundSpec.maxPadding).toDouble());

  set backgroundRadius(double value) =>
      _setBackground(radius: value.clamp(0.0, BackgroundSpec.maxRadius).toDouble());

  set backgroundShadow(bool value) => _setBackground(shadow: value);

  void _setBackground({
    BackgroundKind? kind,
    BackgroundPreset? preset,
    String? imagePath,
    double? padding,
    double? radius,
    bool? shadow,
  }) {
    final b = _background;
    final next = BackgroundSpec(
      kind: kind ?? b.kind,
      preset: preset ?? b.preset,
      imagePath: imagePath ?? b.imagePath,
      padding: padding ?? b.padding,
      radius: radius ?? b.radius,
      shadow: shadow ?? b.shadow,
    );
    if (next.kind == b.kind &&
        next.preset == b.preset &&
        next.imagePath == b.imagePath &&
        next.padding == b.padding &&
        next.radius == b.radius &&
        next.shadow == b.shadow) {
      return;
    }
    _background = next;
    _changed();
  }

  /// The live cursor halo and click ripples (Windows, macOS, Linux on X11).
  static bool get cursorEffectsSupported => liveEffectsSupported;

  /// Auto-zoom needs the mouse position: Windows, macOS and Linux on X11.
  static bool get autoZoomSupported =>
      Platform.isWindows || Platform.isMacOS || platformCanTrackCursor;

  /// Kept for older call sites: any recording effect is available.
  static bool get effectsSupported => cursorEffectsSupported || autoZoomSupported;

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

  /// See [appSettingsFolder].
  static Directory? get settingsFolder => appSettingsFolder();

  static File? get _file {
    final folder = settingsFolder;
    return folder == null ? null : File(p.join(folder.path, 'options.json'));
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
          final size = data['cameraSize'];
          if (size is String) {
            _cameraSize = CameraSize.values.firstWhere(
              (s) => s.name == size,
              orElse: () => _cameraSize,
            );
          }
          _cameraCircle = data['cameraCircle'] as bool? ?? _cameraCircle;
          _cameraFlip = data['cameraFlip'] as bool? ?? _cameraFlip;
          _cameraDevice = data['cameraDevice'] as String?;
          final corner = data['cameraCorner'];
          if (corner is String) {
            _cameraCorner = CameraCorner.values.firstWhere(
              (c) => c.name == corner,
              orElse: () => _cameraCorner,
            );
          }
          final bg = data['background'];
          if (bg is Map) {
            T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
                values.firstWhere((v) => v.name == name, orElse: () => fallback);
            const d = BackgroundSpec();
            final padding = bg['padding'];
            final radius = bg['radius'];
            _background = BackgroundSpec(
              kind: pick(BackgroundKind.values, bg['kind'], d.kind),
              preset: pick(BackgroundPreset.values, bg['preset'], d.preset),
              imagePath: bg['imagePath'] as String?,
              padding: padding is num
                  ? padding.toDouble().clamp(BackgroundSpec.minPadding, BackgroundSpec.maxPadding).toDouble()
                  : d.padding,
              radius: radius is num
                  ? radius.toDouble().clamp(0.0, BackgroundSpec.maxRadius).toDouble()
                  : d.radius,
              shadow: bg['shadow'] as bool? ?? d.shadow,
            );
          }
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
        'cameraSize': _cameraSize.name,
        'cameraCircle': _cameraCircle,
        'cameraFlip': _cameraFlip,
        'cameraCorner': _cameraCorner.name,
        if (_cameraDevice != null) 'cameraDevice': _cameraDevice,
        'background': {
          'kind': _background.kind.name,
          'preset': _background.preset.name,
          if (_background.imagePath != null) 'imagePath': _background.imagePath,
          'padding': _background.padding,
          'radius': _background.radius,
          'shadow': _background.shadow,
        },
      }));
    } catch (_) {}
  }
}
