// Reads the mouse position and button state for auto-zoom, per platform.
//
// Coordinates are in the same pixel space the screen capture uses:
// - Windows: physical virtual-desktop pixels (gdigrab).
// - Linux X11: root-window pixels (x11grab).
// - macOS: main-display pixels, i.e. points × backing scale (avfoundation).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'windows/win32_input.dart';

export 'windows/win32_input.dart' show CursorState;

abstract interface class CursorInput {
  CursorState cursor();
}

/// The cursor reader for this platform, or null where the mouse position
/// can't be read (Wayland doesn't let apps see the global pointer).
CursorInput? platformCursorInput({double macScale = 1}) {
  try {
    if (Platform.isWindows) return Win32Input.instance;
    if (Platform.isMacOS) return MacCursorInput(scale: macScale);
    if (Platform.isLinux && _isX11Session()) return X11CursorInput.open();
  } catch (_) {
    // Missing library or display: auto-zoom simply stays off.
  }
  return null;
}

/// Linux on X11 can read the global mouse position (Wayland can't).
bool get platformCanTrackCursor => Platform.isLinux && _isX11Session();

bool _isX11Session() {
  final session = Platform.environment['XDG_SESSION_TYPE']?.toLowerCase();
  if (session == 'wayland') return false;
  if (session == 'x11') return true;
  return (Platform.environment['WAYLAND_DISPLAY'] ?? '').isEmpty &&
      (Platform.environment['DISPLAY'] ?? '').isNotEmpty;
}

// ---------------------------------------------------------------- X11 ----

typedef _XOpenDisplayC = Pointer<Void> Function(Pointer<Utf8> name);
typedef _XOpenDisplayDart = Pointer<Void> Function(Pointer<Utf8> name);
typedef _XDefaultRootWindowC = UnsignedLong Function(Pointer<Void> display);
typedef _XDefaultRootWindowDart = int Function(Pointer<Void> display);
typedef _XQueryPointerC = Int32 Function(
  Pointer<Void> display,
  UnsignedLong window,
  Pointer<UnsignedLong> rootReturn,
  Pointer<UnsignedLong> childReturn,
  Pointer<Int32> rootX,
  Pointer<Int32> rootY,
  Pointer<Int32> winX,
  Pointer<Int32> winY,
  Pointer<Uint32> mask,
);
typedef _XQueryPointerDart = int Function(
  Pointer<Void> display,
  int window,
  Pointer<UnsignedLong> rootReturn,
  Pointer<UnsignedLong> childReturn,
  Pointer<Int32> rootX,
  Pointer<Int32> rootY,
  Pointer<Int32> winX,
  Pointer<Int32> winY,
  Pointer<Uint32> mask,
);

/// libX11 `XQueryPointer` on the root window.
class X11CursorInput implements CursorInput {
  X11CursorInput._(this._display, this._root, this._query);

  static X11CursorInput? open() {
    final lib = DynamicLibrary.open('libX11.so.6');
    final openDisplay =
        lib.lookupFunction<_XOpenDisplayC, _XOpenDisplayDart>('XOpenDisplay');
    final rootWindow = lib.lookupFunction<_XDefaultRootWindowC,
        _XDefaultRootWindowDart>('XDefaultRootWindow');
    final query =
        lib.lookupFunction<_XQueryPointerC, _XQueryPointerDart>('XQueryPointer');
    final display = openDisplay(nullptr);
    if (display == nullptr) return null;
    return X11CursorInput._(display, rootWindow(display), query);
  }

  final Pointer<Void> _display;
  final int _root;
  final _XQueryPointerDart _query;

  final Pointer<UnsignedLong> _rootRet = calloc<UnsignedLong>();
  final Pointer<UnsignedLong> _childRet = calloc<UnsignedLong>();
  final Pointer<Int32> _x = calloc<Int32>();
  final Pointer<Int32> _y = calloc<Int32>();
  final Pointer<Int32> _wx = calloc<Int32>();
  final Pointer<Int32> _wy = calloc<Int32>();
  final Pointer<Uint32> _mask = calloc<Uint32>();

  static const _button1Mask = 1 << 8;
  static const _button3Mask = 1 << 10;

  @override
  CursorState cursor() {
    _query(_display, _root, _rootRet, _childRet, _x, _y, _wx, _wy, _mask);
    final mask = _mask.value;
    return CursorState(
      _x.value,
      _y.value,
      mask & _button1Mask != 0,
      mask & _button3Mask != 0,
    );
  }
}

// -------------------------------------------------------------- macOS ----

final class _CGPoint extends Struct {
  @Double()
  external double x;

  @Double()
  external double y;
}

typedef _CGEventCreateC = Pointer<Void> Function(Pointer<Void> source);
typedef _CGEventGetLocationC = _CGPoint Function(Pointer<Void> event);
typedef _CGEventSourceButtonStateC = Bool Function(Int32 state, Uint32 button);
typedef _CGEventSourceButtonStateDart = bool Function(int state, int button);
typedef _CFReleaseC = Void Function(Pointer<Void> ref);
typedef _CFReleaseDart = void Function(Pointer<Void> ref);

const _coreGraphicsPath =
    '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics';
const _coreFoundationPath =
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation';

/// CoreGraphics mouse location (global points, top-left origin) scaled to
/// main-display pixels.
class MacCursorInput implements CursorInput {
  MacCursorInput({this.scale = 1}) {
    final cg = DynamicLibrary.open(_coreGraphicsPath);
    final cf = DynamicLibrary.open(_coreFoundationPath);
    _create = cg.lookupFunction<_CGEventCreateC, _CGEventCreateC>('CGEventCreate');
    _location = cg.lookupFunction<_CGEventGetLocationC, _CGEventGetLocationC>(
        'CGEventGetLocation');
    _button = cg.lookupFunction<_CGEventSourceButtonStateC,
        _CGEventSourceButtonStateDart>('CGEventSourceButtonState');
    _release = cf.lookupFunction<_CFReleaseC, _CFReleaseDart>('CFRelease');
  }

  final double scale;
  late final Pointer<Void> Function(Pointer<Void>) _create;
  late final _CGPoint Function(Pointer<Void>) _location;
  late final _CGEventSourceButtonStateDart _button;
  late final _CFReleaseDart _release;

  static const _combinedSessionState = 0;

  @override
  CursorState cursor() {
    final event = _create(nullptr);
    var x = 0.0, y = 0.0;
    if (event != nullptr) {
      final point = _location(event);
      x = point.x;
      y = point.y;
      _release(event);
    }
    return CursorState(
      (x * scale).round(),
      (y * scale).round(),
      _button(_combinedSessionState, 0),
      _button(_combinedSessionState, 1),
    );
  }
}

typedef _CGAccessC = Bool Function();
typedef _CGAccessDart = bool Function();

/// macOS Screen Recording permission (TCC). Both return true elsewhere.
class MacScreenAccess {
  static _CGAccessDart? _lookup(String name) {
    if (!Platform.isMacOS) return null;
    try {
      return DynamicLibrary.open(_coreGraphicsPath)
          .lookupFunction<_CGAccessC, _CGAccessDart>(name);
    } catch (_) {
      return null;
    }
  }

  /// Whether this app may record the screen right now.
  static bool get granted =>
      _lookup('CGPreflightScreenCaptureAccess')?.call() ?? true;

  /// Shows the system prompt (first time) and adds the app to the list in
  /// System Settings. macOS only applies a new grant after a restart.
  static bool request() =>
      _lookup('CGRequestScreenCaptureAccess')?.call() ?? true;
}
