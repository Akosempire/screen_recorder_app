import 'dart:io';

import 'package:flutter/material.dart';

import '../controllers/region_selection_controller.dart';
import '../models/display_server.dart';
import '../models/screen_region.dart';
import '../widgets/selection_rectangle.dart';

class RegionSelectionScreen extends StatefulWidget {
  const RegionSelectionScreen({
    super.key,
    required this.geometry,
    required this.onRecord,
    required this.onCancel,
    this.snapshot,
    this.selection,
    this.onRegionChanged,
    this.recordMicrophone = false,
    this.onRecordMicrophoneChanged,
  });

  final DesktopGeometry geometry;
  final File? snapshot;
  final RegionSelectionController? selection;
  final ValueChanged<ScreenRegion> onRecord;
  final VoidCallback onCancel;
  final ValueChanged<ScreenRegion>? onRegionChanged;
  final bool recordMicrophone;
  final ValueChanged<bool>? onRecordMicrophoneChanged;

  @override
  State<RegionSelectionScreen> createState() => _RegionSelectionScreenState();
}

class _RegionSelectionScreenState extends State<RegionSelectionScreen> {
  late final RegionSelectionController _selection;
  Offset _cursor = Offset.zero;

  @override
  void initState() {
    super.initState();
    _selection = widget.selection ?? RegionSelectionController();
    _selection.addListener(_onSelectionChanged);
  }

  @override
  void dispose() {
    _selection.removeListener(_onSelectionChanged);
    if (widget.selection == null) {
      _selection.dispose();
    }
    super.dispose();
  }

  void _onSelectionChanged() {
    final region = _desktopRegion();
    if (region != null) {
      widget.onRegionChanged?.call(region);
    }
  }

  ScreenRegion? _desktopRegion() {
    final local = _selection.region;
    if (local == null || _selection.overlaySize.isEmpty) {
      return null;
    }
    return widget.geometry.mapOverlayRect(
      RectLike(
        left: local.left,
        top: local.top,
        width: local.width,
        height: local.height,
      ),
      SizeLike(
        width: _selection.overlaySize.width,
        height: _selection.overlaySize.height,
      ),
    );
  }

  void _record() {
    final region = _desktopRegion();
    if (region == null || !region.isValid) {
      return;
    }
    widget.onRecord(region);
  }

  MouseCursor _cursorFor(Offset position) {
    switch (_selection.hitHandle(position)) {
      case ResizeHandle.topLeft:
      case ResizeHandle.bottomRight:
        return SystemMouseCursors.resizeUpLeftDownRight;
      case ResizeHandle.topRight:
      case ResizeHandle.bottomLeft:
        return SystemMouseCursors.resizeUpRightDownLeft;
      case ResizeHandle.top:
      case ResizeHandle.bottom:
        return SystemMouseCursors.resizeUpDown;
      case ResizeHandle.left:
      case ResizeHandle.right:
        return SystemMouseCursors.resizeLeftRight;
      case null:
        if (_selection.region?.contains(position) == true) {
          return SystemMouseCursors.move;
        }
        return SystemMouseCursors.precise;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        scaffoldBackgroundColor: const Color(0xFF111111),
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF111111),
        body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _selection.setOverlaySize(size);
            }
          });
          return AnimatedBuilder(
            animation: _selection,
            builder: (context, _) {
              final desktop = _desktopRegion();
              final canRecord = _selection.hasValidRegion &&
                  desktop != null &&
                  desktop.isValid;
              return Stack(
                fit: StackFit.expand,
                children: [
                  MouseRegion(
                    cursor: _cursorFor(_cursor),
                    onHover: (event) => _cursor = event.localPosition,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) =>
                          _selection.pointerDown(event.localPosition),
                      onPointerMove: (event) {
                        _cursor = event.localPosition;
                        _selection.pointerMove(event.localPosition);
                      },
                      onPointerUp: (event) =>
                          _selection.pointerUp(event.localPosition),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (widget.snapshot != null)
                            Image.file(
                              widget.snapshot!,
                              fit: BoxFit.fill,
                              filterQuality: FilterQuality.medium,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                color: Color(0xFF111111),
                              ),
                            )
                          else
                            const ColoredBox(color: Color(0xFF111111)),
                          CustomPaint(
                            painter: SelectionDimPainter(
                              region: _selection.region,
                              color: widget.snapshot == null
                                  ? const Color(0xCC000000)
                                  : const Color(0x66000000),
                            ),
                          ),
                          SelectionRectangle(controller: _selection),
                          if (desktop != null)
                            _InfoBadge(
                              region: _selection.region!,
                              desktop: desktop,
                            ),
                          if (widget.snapshot == null)
                            const Align(
                              alignment: Alignment.topCenter,
                              child: Padding(
                                padding: EdgeInsets.only(top: 24),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Color(0xE0121418),
                                    borderRadius:
                                        BorderRadius.all(Radius.circular(8)),
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      'Desktop preview unavailable — the red box is still the area that will be recorded.',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 24,
                    child: Center(
                      child: _ActionBar(
                        canRecord: canRecord,
                        onRecord: _record,
                        onCancel: widget.onCancel,
                        recordMicrophone: widget.recordMicrophone,
                        onRecordMicrophoneChanged:
                            widget.onRecordMicrophoneChanged,
                        hint: canRecord
                            ? 'Resize or move the box, then Record'
                            : 'Drag on the desktop to select what to record',
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
        ),
      ),
    );
  }
}

class _InfoBadge extends StatelessWidget {
  const _InfoBadge({required this.region, required this.desktop});

  final Rect region;
  final ScreenRegion desktop;

  @override
  Widget build(BuildContext context) {
    final top = region.top < 72 ? region.bottom + 8 : region.top - 64;
    return Positioned(
      left: region.left.clamp(8, double.infinity),
      top: top.clamp(8, double.infinity),
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xE0121418),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: DefaultTextStyle(
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                height: 1.35,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${desktop.width} × ${desktop.height}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text('X: ${desktop.x}'),
                  Text('Y: ${desktop.y}'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.canRecord,
    required this.onRecord,
    required this.onCancel,
    required this.hint,
    required this.recordMicrophone,
    this.onRecordMicrophoneChanged,
  });

  final bool canRecord;
  final VoidCallback onRecord;
  final VoidCallback onCancel;
  final String hint;
  final bool recordMicrophone;
  final ValueChanged<bool>? onRecordMicrophoneChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xF0161A20),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              hint,
              style: const TextStyle(color: Color(0xFFB0BEC5), fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MicrophoneToggle(
                  enabled: recordMicrophone,
                  onChanged: onRecordMicrophoneChanged,
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFCFD8DC),
                  ),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: canRecord ? onRecord : null,
                  icon: const Icon(Icons.fiber_manual_record, size: 16),
                  label: const Text('Record'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),
                    disabledBackgroundColor: const Color(0xFF8B2E2E),
                    foregroundColor: Colors.white,
                    disabledForegroundColor: const Color(0xFFE0E0E0),
                    elevation: canRecord ? 3 : 0,
                    shadowColor: const Color(0x80E53935),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MicrophoneToggle extends StatelessWidget {
  const _MicrophoneToggle({
    required this.enabled,
    this.onChanged,
  });

  final bool enabled;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: enabled
          ? 'Microphone on — your voice will be in the video'
          : 'Microphone off — video only',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            enabled ? Icons.mic : Icons.mic_off,
            size: 16,
            color: enabled
                ? const Color(0xFF26A69A)
                : const Color(0xFF90A4AE),
          ),
          const SizedBox(width: 6),
          const Text(
            'Microphone',
            style: TextStyle(color: Color(0xFFCFD8DC), fontSize: 12),
          ),
          const SizedBox(width: 4),
          Switch(
            value: enabled,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}
