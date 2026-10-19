// Minimal user32 bindings used on Windows: virtual-screen bounds, cursor
// position, and mouse-button state. All coordinates are physical pixels
// because the Flutter runner is per-monitor DPI aware, which matches the
// coordinate space FFmpeg gdigrab uses for `-offset_x/-offset_y`.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../cursor_input.dart' show CursorInput;

final class _Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

typedef _GetSystemMetricsC = Int32 Function(Int32 index);
typedef _GetSystemMetricsDart = int Function(int index);
typedef _GetCursorPosC = Int32 Function(Pointer<_Point> point);
typedef _GetCursorPosDart = int Function(Pointer<_Point> point);
typedef _GetAsyncKeyStateC = Int16 Function(Int32 key);
typedef _GetAsyncKeyStateDart = int Function(int key);

class VirtualScreen {
  final int x;
  final int y;
  final int width;
  final int height;

  const VirtualScreen(this.x, this.y, this.width, this.height);

  @override
  String toString() => 'VirtualScreen(${width}x$height+$x+$y)';
}

class CursorState {
  final int x;
  final int y;
  final bool leftDown;
  final bool rightDown;

  const CursorState(this.x, this.y, this.leftDown, this.rightDown);
}

/// Thin wrapper over user32.dll. Only constructed on Windows.
class Win32Input implements CursorInput {
  Win32Input._(DynamicLibrary user32)
      : _getSystemMetrics = user32.lookupFunction<_GetSystemMetricsC,
            _GetSystemMetricsDart>('GetSystemMetrics'),
        _getCursorPos = user32
            .lookupFunction<_GetCursorPosC, _GetCursorPosDart>('GetCursorPos'),
        _getAsyncKeyState = user32.lookupFunction<_GetAsyncKeyStateC,
            _GetAsyncKeyStateDart>('GetAsyncKeyState'),
        _point = calloc<_Point>();

  static Win32Input? _instance;

  /// Null when not running on Windows.
  static Win32Input? get instance {
    if (!Platform.isWindows) {
      return null;
    }
    return _instance ??= Win32Input._(DynamicLibrary.open('user32.dll'));
  }

  final _GetSystemMetricsDart _getSystemMetrics;
  final _GetCursorPosDart _getCursorPos;
  final _GetAsyncKeyStateDart _getAsyncKeyState;
  final Pointer<_Point> _point;

  static const _smXVirtualScreen = 76;
  static const _smYVirtualScreen = 77;
  static const _smCxVirtualScreen = 78;
  static const _smCyVirtualScreen = 79;
  static const _smCxScreen = 0;
  static const _smCyScreen = 1;
  static const _vkLButton = 0x01;
  static const _vkRButton = 0x02;
  static const _smSwapButton = 23;

  VirtualScreen virtualScreen() {
    return VirtualScreen(
      _getSystemMetrics(_smXVirtualScreen),
      _getSystemMetrics(_smYVirtualScreen),
      _getSystemMetrics(_smCxVirtualScreen),
      _getSystemMetrics(_smCyVirtualScreen),
    );
  }

  /// Primary monitor size in physical pixels.
  (int, int) primarySize() =>
      (_getSystemMetrics(_smCxScreen), _getSystemMetrics(_smCyScreen));

  @override
  CursorState cursor() {
    _getCursorPos(_point);
    // GetAsyncKeyState reports physical buttons; honour swapped buttons.
    final swapped = _getSystemMetrics(_smSwapButton) != 0;
    final physicalLeft = (_getAsyncKeyState(_vkLButton) & 0x8000) != 0;
    final physicalRight = (_getAsyncKeyState(_vkRButton) & 0x8000) != 0;
    return CursorState(
      _point.ref.x,
      _point.ref.y,
      swapped ? physicalRight : physicalLeft,
      swapped ? physicalLeft : physicalRight,
    );
  }
}
