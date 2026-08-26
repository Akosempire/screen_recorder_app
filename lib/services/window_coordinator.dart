import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../models/display_server.dart';
import '../models/screen_region.dart';
import 'app_logger.dart';
import 'desktop_snapshot_service.dart';
import 'native_window.dart';
import 'selector_backdrop.dart';

class WindowCoordinator {
  static const Size homeSize = Size(460, 420);
  static const Size recordingSize = Size(128, 72);
  static const Color opaqueBackground = Color(0xFF121418);
  static const Color liveBackground = Color(0x00000000);

  WindowCoordinator({
    DesktopSnapshotService? snapshots,
    NativeWindowService? nativeWindow,
  })  : _snapshots = snapshots ?? DesktopSnapshotService(),
        _nativeWindow = nativeWindow ?? NativeWindowService();

  final DesktopSnapshotService _snapshots;
  final NativeWindowService _nativeWindow;
  File? _snapshot;
  final List<String> _windowOps = [];

  File? get snapshot => _snapshot;

  @visibleForTesting
  List<String> get windowOps => List<String>.unmodifiable(_windowOps);

  Future<void> showHome() async {
    await _setOpaqueChrome();
    await _call('setFullScreen(false)', () => windowManager.setFullScreen(false));
    await _call('unmaximize', () => windowManager.unmaximize());
    await _call(
      'clearMaximumSize',
      () => windowManager.setMaximumSize(const Size(10000, 10000)),
    );
    await _call('setAlwaysOnTop(false)', () => windowManager.setAlwaysOnTop(false));
    await _call('setSkipTaskbar(false)', () => windowManager.setSkipTaskbar(false));
    await _call(
      'setTitleBarStyle(normal)',
      () => windowManager.setTitleBarStyle(
        TitleBarStyle.normal,
        windowButtonVisibility: true,
      ),
    );
    await _call(
      'setMinimumSize(home)',
      () => windowManager.setMinimumSize(const Size(400, 360)),
    );
    await _call('setResizable(true)', () => windowManager.setResizable(true));
    await _call('setSize(home)', () => windowManager.setSize(homeSize));
    await _call('setTitle', () => windowManager.setTitle('Screen Recorder'));
    await _call('setOpacity(1)', () => windowManager.setOpacity(1));
    await _call('center', () => windowManager.center());
    await _call('show', () => windowManager.show());
    await _call('focus', () => windowManager.focus());
  }

  /// Maps the selector overlay. [backdrop] is chosen before this is called.
  Future<File?> enterSelection(
    DesktopGeometry geometry, {
    SelectorBackdrop backdrop = SelectorBackdrop.snapshot,
  }) {
    if (backdrop == SelectorBackdrop.liveHole) {
      return enterLiveSelection(geometry);
    }
    return enterSnapshotSelection(geometry);
  }

  /// Takes a desktop still, then covers the screen with that image for region
  /// selection.
  ///
  /// The window stays mapped **and focused**. GNOME only shows the screenshot
  /// portal dialog for the focused app; fading to opacity 0 first made Mutter
  /// deny the dialog and left a black selector.
  Future<File?> enterSnapshotSelection(DesktopGeometry geometry) async {
    await _call('setAlwaysOnTop(false)', () => windowManager.setAlwaysOnTop(false));
    await _call('setSkipTaskbar(false)', () => windowManager.setSkipTaskbar(false));
    await _call('setOpacity(1)', () => windowManager.setOpacity(1));
    await _call('show', () => windowManager.show());
    await _call('focus', () => windowManager.focus());

    var parent = await _nativeWindow.parentWindowHandle();
    AppLogger.info(
      'Snapshot capture parent_window=${parent.isEmpty ? '(none)' : parent}',
    );

    _snapshot = await _snapshots.capture(geometry, parentWindow: parent);

    if (_snapshot == null) {
      AppLogger.info(
        'Snapshot failed while mapped; retrying focused so GNOME can prompt',
      );
      await _call('setOpacity(1)', () => windowManager.setOpacity(1));
      await _call('show', () => windowManager.show());
      await _call('focus', () => windowManager.focus());
      _snapshot = await _snapshots.capture(geometry, parentWindow: parent);
    } else {
      // Permission is cached. Fade so the second still is the real desktop.
      await _call('setOpacity(0)', () => windowManager.setOpacity(0));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final clean = await _snapshots.capture(geometry, parentWindow: parent);
      if (clean != null) {
        _snapshot = clean;
      }
      await _call('setOpacity(1)', () => windowManager.setOpacity(1));
    }

    AppLogger.info(
      _snapshot == null
          ? 'No desktop snapshot; overlay will not show a live preview'
          : 'Desktop snapshot ready: ${_snapshot!.path}',
    );

    await _applySelectorChrome();
    await _setBackground(opaqueBackground, 'opaque');
    await _call('setOpacity(1)', () => windowManager.setOpacity(1));
    await _call('show', () => windowManager.show());
    await _call('focus', () => windowManager.focus());
    return _snapshot;
  }

  /// Live compositor hole. No still, no whole-window fade. Per-pixel alpha in
  /// the hole is a different knob from [windowManager.setOpacity].
  Future<File?> enterLiveSelection(DesktopGeometry geometry) async {
    _snapshot = null;
    await _call('setAlwaysOnTop(false)', () => windowManager.setAlwaysOnTop(false));
    await _call('setSkipTaskbar(false)', () => windowManager.setSkipTaskbar(false));
    await _call('setOpacity(1)', () => windowManager.setOpacity(1));
    await _call('show', () => windowManager.show());

    AppLogger.info(
      'Live selector on ${geometry.displayServer.name} '
      '${geometry.width}x${geometry.height}',
    );

    await _applySelectorChrome();
    await _setBackground(liveBackground, 'transparent');
    await _call('setOpacity(1)', () => windowManager.setOpacity(1));
    await _call('show', () => windowManager.show());
    await _call('focus', () => windowManager.focus());
    return null;
  }

  Future<void> _applySelectorChrome() async {
    await _call('setAsFrameless', () => windowManager.setAsFrameless());
    await _call(
      'setTitleBarStyle(hidden)',
      () => windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
    );
    await _call('setAlwaysOnTop(true)', () => windowManager.setAlwaysOnTop(true));
    await _call('setSkipTaskbar(true)', () => windowManager.setSkipTaskbar(true));
    await _call('setResizable(true)', () => windowManager.setResizable(true));
    await _call(
      'clearMaximumSize',
      () => windowManager.setMaximumSize(const Size(10000, 10000)),
    );
    await _call(
      'setMinimumSize(overlay)',
      () => windowManager.setMinimumSize(const Size(1, 1)),
    );

    await _call('setFullScreen(true)', () => windowManager.setFullScreen(true));
    final bounds = await _logicalDesktopBounds();
    if (bounds != null && bounds.width > 0 && bounds.height > 0) {
      await _call('setBounds(desktop)', () => windowManager.setBounds(bounds));
    }
  }

  /// Hide the overlay, leave fullscreen, and shrink to the floating chip
  /// so the real desktop is visible while recording.
  Future<void> prepareRecordingChrome({Offset? position}) async {
    await _setOpaqueChrome();
    await _call('hide', () => windowManager.hide());
    await _call('setFullScreen(false)', () => windowManager.setFullScreen(false));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _call('unmaximize', () => windowManager.unmaximize());
    await _call('setAsFrameless', () => windowManager.setAsFrameless());
    await _call(
      'setTitleBarStyle(hidden)',
      () => windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
    );
    await _call('setAlwaysOnTop(true)', () => windowManager.setAlwaysOnTop(true));
    await _call('setSkipTaskbar(false)', () => windowManager.setSkipTaskbar(false));
    await _call('setResizable(false)', () => windowManager.setResizable(false));
    await _shrinkToRecordingChip(position ?? const Offset(24, 24));
    await _call('setTitle', () => windowManager.setTitle('Recording'));
    await _call('setOpacity(1)', () => windowManager.setOpacity(1));
    await _setBackground(opaqueBackground, 'opaque');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  Future<void> showRecordingControls({
    required ScreenRegion captureRegion,
    required DesktopGeometry geometry,
  }) async {
    final position = await controlPosition(captureRegion) ?? const Offset(24, 24);
    await _shrinkToRecordingChip(position);
    await _call('show', () => windowManager.show());
    await _call('focus', () => windowManager.focus());
  }

  Future<void> _setOpaqueChrome() async {
    await _setBackground(opaqueBackground, 'opaque');
    await _nativeWindow.clearOpaqueRegion();
    _windowOps.add('clearOpaqueRegion');
  }

  Future<void> _setBackground(Color color, String label) async {
    await _call(
      'setBackgroundColor($label)',
      () => windowManager.setBackgroundColor(color),
    );
  }

  Future<void> _shrinkToRecordingChip(Offset position) async {
    await _call(
      'setMinimumSize(recording)',
      () => windowManager.setMinimumSize(recordingSize),
    );
    await _call(
      'setMaximumSize(recording)',
      () => windowManager.setMaximumSize(recordingSize),
    );
    final bounds = Rect.fromLTWH(
      position.dx,
      position.dy,
      recordingSize.width,
      recordingSize.height,
    );
    await _call('setBounds(recording)', () => windowManager.setBounds(bounds));
    await _call('setSize(recording)', () => windowManager.setSize(recordingSize));
    try {
      final size = await windowManager.getSize();
      AppLogger.info('Recording chrome size: ${size.width}x${size.height}');
      if (size.width > recordingSize.width + 40 ||
          size.height > recordingSize.height + 40) {
        AppLogger.warn(
          'Recording window stayed large (${size.width}x${size.height}); retrying bounds',
        );
        await _call('setFullScreen(false)', () => windowManager.setFullScreen(false));
        await _call('unmaximize', () => windowManager.unmaximize());
        await _call('setBounds(recording retry)', () => windowManager.setBounds(bounds));
      }
    } catch (error) {
      AppLogger.debug('Could not verify recording chrome size: $error');
    }
  }

  Future<void> _call(String label, Future<void> Function() action) async {
    _windowOps.add(label);
    try {
      await action();
    } on MissingPluginException catch (error) {
      AppLogger.debug('window_manager $label skipped: $error');
    } catch (error, stack) {
      AppLogger.debug('window_manager $label failed: $error\n$stack');
    }
  }

  Future<Rect?> _logicalDesktopBounds() async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) {
        return null;
      }
      var minX = double.infinity;
      var minY = double.infinity;
      var maxX = -double.infinity;
      var maxY = -double.infinity;
      for (final display in displays) {
        final origin = display.visiblePosition ?? Offset.zero;
        minX = math.min(minX, origin.dx);
        minY = math.min(minY, origin.dy);
        maxX = math.max(maxX, origin.dx + display.size.width);
        maxY = math.max(maxY, origin.dy + display.size.height);
      }
      return Rect.fromLTRB(minX, minY, maxX, maxY);
    } catch (error, stack) {
      AppLogger.debug('logical desktop bounds failed: $error\n$stack');
      return null;
    }
  }

  Future<Offset?> controlPosition(ScreenRegion captureRegion) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) {
        return const Offset(24, 24);
      }
      var minX = double.infinity;
      var minY = double.infinity;
      var maxX = -double.infinity;
      var maxY = -double.infinity;
      for (final display in displays) {
        final origin = display.visiblePosition ?? Offset.zero;
        minX = math.min(minX, origin.dx);
        minY = math.min(minY, origin.dy);
        maxX = math.max(maxX, origin.dx + display.size.width);
        maxY = math.max(maxY, origin.dy + display.size.height);
      }

      final capture = Rect.fromLTWH(
        captureRegion.x.toDouble(),
        captureRegion.y.toDouble(),
        captureRegion.width.toDouble(),
        captureRegion.height.toDouble(),
      );
      const pad = 16.0;
      final candidates = <Offset>[
        Offset(minX + pad, minY + pad),
        Offset(maxX - recordingSize.width - pad, minY + pad),
        Offset(minX + pad, maxY - recordingSize.height - pad),
        Offset(
          maxX - recordingSize.width - pad,
          maxY - recordingSize.height - pad,
        ),
      ];
      for (final candidate in candidates) {
        final controls = Rect.fromLTWH(
          candidate.dx,
          candidate.dy,
          recordingSize.width,
          recordingSize.height,
        );
        if (!controls.overlaps(capture)) {
          return candidate;
        }
      }
      return Offset(minX + pad, minY + pad);
    } catch (error, stack) {
      AppLogger.debug('control position failed: $error\n$stack');
      return const Offset(24, 24);
    }
  }
}
