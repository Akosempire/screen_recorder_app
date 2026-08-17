import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Resize handles around the selection rectangle.
enum ResizeHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,
}

enum SelectionGesture {
  none,
  creating,
  moving,
  resizing,
}

/// Overlay-local logical-pixel selection. Convert to [ScreenRegion] via
/// [DesktopGeometry.mapOverlayRect] once the overlay size is known.
class RegionSelectionController extends ChangeNotifier {
  static const double minSize = 100;
  static const double handleVisualSize = 8;
  static const double handleHitSize = 14;

  Rect? _region;
  Size _overlaySize = Size.zero;
  SelectionGesture _gesture = SelectionGesture.none;
  ResizeHandle? _activeHandle;
  Offset? _pointerOrigin;
  Rect? _regionAtGestureStart;

  Rect? get region => _region;
  Size get overlaySize => _overlaySize;
  SelectionGesture get gesture => _gesture;
  ResizeHandle? get activeHandle => _activeHandle;

  bool get hasValidRegion {
    final region = _region;
    if (region == null) {
      return false;
    }
    return region.width >= minSize && region.height >= minSize;
  }

  void setOverlaySize(Size size) {
    if (size.isEmpty) {
      return;
    }
    final sizeChanged = size != _overlaySize;
    _overlaySize = size;
    if (_region != null) {
      _region = _clamp(_region!);
    } else if (sizeChanged) {
      _applyDefaultRegion();
    }
    notifyListeners();
  }

  void clear() {
    _gesture = SelectionGesture.none;
    _activeHandle = null;
    _pointerOrigin = null;
    _regionAtGestureStart = null;
    _region = null;
    if (!_overlaySize.isEmpty) {
      _applyDefaultRegion();
    }
    notifyListeners();
  }

  void _applyDefaultRegion() {
    if (_overlaySize.isEmpty) {
      return;
    }
    final width = math.max(
      minSize,
      math.min(_overlaySize.width * 0.45, _overlaySize.width - 48),
    );
    final height = math.max(
      minSize,
      math.min(_overlaySize.height * 0.45, _overlaySize.height - 48),
    );
    final left = (_overlaySize.width - width) / 2;
    final top = (_overlaySize.height - height) / 2;
    _region = _clamp(Rect.fromLTWH(left, top, width, height));
  }

  void pointerDown(Offset position) {
    final handle = hitHandle(position);
    if (handle != null && _region != null) {
      _gesture = SelectionGesture.resizing;
      _activeHandle = handle;
      _pointerOrigin = position;
      _regionAtGestureStart = _region;
      notifyListeners();
      return;
    }
    if (_region != null && _hitsMoveArea(position)) {
      _gesture = SelectionGesture.moving;
      _activeHandle = null;
      _pointerOrigin = position;
      _regionAtGestureStart = _region;
      notifyListeners();
      return;
    }
    _gesture = SelectionGesture.creating;
    _activeHandle = null;
    _pointerOrigin = position;
    _regionAtGestureStart = null;
    _region = Rect.fromLTWH(position.dx, position.dy, 0, 0);
    notifyListeners();
  }

  void pointerMove(Offset position) {
    switch (_gesture) {
      case SelectionGesture.none:
        return;
      case SelectionGesture.creating:
        final origin = _pointerOrigin;
        if (origin == null) {
          return;
        }
        _region = _clamp(_normalize(origin, position));
        notifyListeners();
      case SelectionGesture.moving:
        final origin = _pointerOrigin;
        final start = _regionAtGestureStart;
        if (origin == null || start == null) {
          return;
        }
        final delta = position - origin;
        _region = _clamp(start.shift(delta));
        notifyListeners();
      case SelectionGesture.resizing:
        final start = _regionAtGestureStart;
        final handle = _activeHandle;
        if (start == null || handle == null) {
          return;
        }
        _region = _clamp(_resize(start, handle, position));
        notifyListeners();
    }
  }

  void pointerUp(Offset position) {
    pointerMove(position);
    _gesture = SelectionGesture.none;
    _activeHandle = null;
    _pointerOrigin = null;
    _regionAtGestureStart = null;
    if (_region != null && (_region!.width < 4 || _region!.height < 4)) {
      _region = null;
    }
    notifyListeners();
  }

  ResizeHandle? hitHandle(Offset position) {
    final region = _region;
    if (region == null) {
      return null;
    }
    for (final handle in ResizeHandle.values) {
      if (handleRect(handle).inflate((handleHitSize - handleVisualSize) / 2).contains(position)) {
        return handle;
      }
    }
    return null;
  }

  Rect handleRect(ResizeHandle handle) {
    final region = _region;
    if (region == null) {
      return Rect.zero;
    }
    final cx = region.center.dx;
    final cy = region.center.dy;
    late final Offset center;
    switch (handle) {
      case ResizeHandle.topLeft:
        center = region.topLeft;
      case ResizeHandle.top:
        center = Offset(cx, region.top);
      case ResizeHandle.topRight:
        center = region.topRight;
      case ResizeHandle.right:
        center = Offset(region.right, cy);
      case ResizeHandle.bottomRight:
        center = region.bottomRight;
      case ResizeHandle.bottom:
        center = Offset(cx, region.bottom);
      case ResizeHandle.bottomLeft:
        center = region.bottomLeft;
      case ResizeHandle.left:
        center = Offset(region.left, cy);
    }
    return Rect.fromCenter(
      center: center,
      width: handleVisualSize,
      height: handleVisualSize,
    );
  }

  bool _hitsMoveArea(Offset position) {
    final region = _region;
    if (region == null) {
      return false;
    }
    return region.contains(position) && hitHandle(position) == null;
  }

  Rect _normalize(Offset a, Offset b) {
    return Rect.fromPoints(a, b);
  }

  Rect _resize(Rect start, ResizeHandle handle, Offset position) {
    var left = start.left;
    var top = start.top;
    var right = start.right;
    var bottom = start.bottom;

    switch (handle) {
      case ResizeHandle.topLeft:
        left = position.dx;
        top = position.dy;
      case ResizeHandle.top:
        top = position.dy;
      case ResizeHandle.topRight:
        right = position.dx;
        top = position.dy;
      case ResizeHandle.right:
        right = position.dx;
      case ResizeHandle.bottomRight:
        right = position.dx;
        bottom = position.dy;
      case ResizeHandle.bottom:
        bottom = position.dy;
      case ResizeHandle.bottomLeft:
        left = position.dx;
        bottom = position.dy;
      case ResizeHandle.left:
        left = position.dx;
    }

    if (right - left < minSize) {
      if (handle == ResizeHandle.left ||
          handle == ResizeHandle.topLeft ||
          handle == ResizeHandle.bottomLeft) {
        left = right - minSize;
      } else {
        right = left + minSize;
      }
    }
    if (bottom - top < minSize) {
      if (handle == ResizeHandle.top ||
          handle == ResizeHandle.topLeft ||
          handle == ResizeHandle.topRight) {
        top = bottom - minSize;
      } else {
        bottom = top + minSize;
      }
    }

    return Rect.fromLTRB(left, top, right, bottom);
  }

  Rect _clamp(Rect rect) {
    if (_overlaySize.isEmpty) {
      return rect;
    }
    var width = math.min(rect.width, _overlaySize.width);
    var height = math.min(rect.height, _overlaySize.height);
    width = math.max(0, width);
    height = math.max(0, height);
    final left = rect.left.clamp(0, _overlaySize.width - width);
    final top = rect.top.clamp(0, _overlaySize.height - height);
    return Rect.fromLTWH(left.toDouble(), top.toDouble(), width, height);
  }
}
