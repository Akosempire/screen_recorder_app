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
import 'linux_desktop.dart';
import 'native_window.dart';
import 'selector_backdrop.dart';

/// Process-local screenshot-portal trust. Hide-first runs when
/// `trust != untrusted`: a real GNOME session returned a file at opacity 0
/// after Allow, so `unknown` is treated like `trusted`.
enum PortalTrust { unknown, trusted, untrusted }

class WindowCoordinator {
  static Size get homeSize =>
      Platform.isWindows ? const Size(460, 560) : const Size(460, 420);
  static const Size recordingSize = Size(156, 40);
  static const Color opaqueBackground = Color(0xFF121418);
  static const Color liveBackground = Color(0x00000000);
  static const Duration _hideFade = Duration(milliseconds: 200);
  static const Duration _hideFirstTimeout = Duration(seconds: 2);
  static const Duration _focusedTimeout = Duration(seconds: 45);

  WindowCoordinator({
    DesktopSnapshotService? snapshots,
    NativeWindowService? nativeWindow,
    bool Function()? isGnomeDesktop,
  })  : _snapshots = snapshots ?? DesktopSnapshotService(),
        _nativeWindow = nativeWindow ?? NativeWindowService(),
        _isGnomeDesktop = isGnomeDesktop ?? (() => LinuxDesktop.isGnome);

  final DesktopSnapshotService _snapshots;
  final NativeWindowService _nativeWindow;
  final bool Function() _isGnomeDesktop;
  File? _snapshot;
  PortalTrust _trust = PortalTrust.unknown;
  final List<String> _windowOps = [];

  File? get snapshot => _snapshot;

  @visibleForTesting
  List<String> get windowOps => List<String>.unmodifiable(_windowOps);

  @visibleForTesting
  PortalTrust get portalTrust => _trust;

  @visibleForTesting
  set portalTrust(PortalTrust value) => _trust = value;

  Future<void> showHome() async {
    await _nativeWindow.clearFixedBounds();
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
  /// Stays at opacity 0 until [revealSelector] — AppShell fades in after
  /// the selector widget is built. Never [windowManager.hide].
  Future<File?> enterSnapshotSelection(DesktopGeometry geometry) async {
    await _call('setAlwaysOnTop(false)', () => windowManager.setAlwaysOnTop(false));
    await _call('setSkipTaskbar(false)', () => windowManager.setSkipTaskbar(false));
    await _call('setOpacity(1)', () => windowManager.setOpacity(1));
    await _call('show', () => windowManager.show());
    await _call('focus', () => windowManager.focus());

    final parent = await _nativeWindow.parentWindowHandle();
    AppLogger.info(
      'Snapshot capture parent_window=${parent.isEmpty ? '(none)' : parent}',
    );

    final gnomePortal =
        geometry.displayServer == DisplayServer.wayland && _isGnomeDesktop();
    var usedFocused = false;
    var finishedHidden = false;

    try {
      if (gnomePortal &&
          parent.isNotEmpty &&
          _trust != PortalTrust.untrusted) {
        AppLogger.info(
          'GNOME portal hide-first (trust=$_trust, timeout=2s)',
        );
        await _call('setOpacity(0)', () => windowManager.setOpacity(0));
        await Future<void>.delayed(_hideFade);
        final hidden = await _snapshots.capturePortal(
          geometry,
          parentWindow: parent,
          timeout: _hideFirstTimeout,
        );
        if (hidden.success) {
          _snapshot = hidden.file;
          _trust = PortalTrust.trusted;
          await _finishSelectorHidden();
          finishedHidden = true;
          return _snapshot;
        }
        if (hidden.status == PortalCaptureStatus.cancelled ||
            hidden.status == PortalCaptureStatus.failed) {
          _trust = PortalTrust.untrusted;
        }
        await _restoreVisible();
      } else if (gnomePortal && parent.isEmpty) {
        AppLogger.info(
          'GNOME portal parent_window empty; skipping hide-first',
        );
      }

      if (gnomePortal) {
        usedFocused = true;
        AppLogger.info('GNOME portal focused (timeout=45s)');
        var focused = await _snapshots.capturePortal(
          geometry,
          parentWindow: parent,
          timeout: _focusedTimeout,
        );
        if (focused.status == PortalCaptureStatus.cancelled) {
          _snapshot = null;
        } else if (!focused.success) {
          await _restoreVisible();
          focused = await _snapshots.capturePortal(
            geometry,
            parentWindow: parent,
            timeout: _focusedTimeout,
          );
          _snapshot = focused.file;
        } else {
          _snapshot = focused.file;
        }

        if (usedFocused && _snapshot != null) {
          AppLogger.info('GNOME portal B recapture after focused still');
          await _call('setOpacity(0)', () => windowManager.setOpacity(0));
          await Future<void>.delayed(_hideFade);
          final clean = await _snapshots.capturePortal(
            geometry,
            parentWindow: parent,
            timeout: _hideFirstTimeout,
          );
          if (clean.success) {
            _snapshot = clean.file;
            _trust = PortalTrust.trusted;
          }
        }
      } else {
        await _call('setOpacity(0)', () => windowManager.setOpacity(0));
        await Future<void>.delayed(_hideFade);
        _snapshot = await _snapshots.capture(geometry, parentWindow: parent);
        if (_snapshot == null) {
          await _restoreVisible();
          _snapshot = await _snapshots.capture(geometry, parentWindow: parent);
        }
      }

      AppLogger.info(
        _snapshot == null
            ? 'No desktop snapshot; overlay will not show a live preview'
            : 'Desktop snapshot ready: ${_snapshot!.path}',
      );

      await _finishSelectorHidden();
      finishedHidden = true;
      return _snapshot;
    } finally {
      if (!finishedHidden) {
        await _restoreVisible();
      }
    }
  }

  /// Fade the selector in after Flutter has swapped to the overlay.
  Future<void> revealSelector() async {
    await _call('setOpacity(1)', () => windowManager.setOpacity(1));
    await _call('show', () => windowManager.show());
    await _call('focus', () => windowManager.focus());
  }

  Future<void> _restoreVisible() async {
    await _call('setOpacity(1)', () => windowManager.setOpacity(1));
    await _call('show', () => windowManager.show());
    await _call('focus', () => windowManager.focus());
  }

  Future<void> _finishSelectorHidden() async {
    await _call('setOpacity(0)', () => windowManager.setOpacity(0));
    await _applySelectorChrome();
    await _setBackground(opaqueBackground, 'opaque');
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
    await _nativeWindow.clearFixedBounds();
    if (Platform.isWindows) {
      await _applyWindowsSelectorChrome();
      return;
    }
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

  /// Windows: window_manager's `setAsFrameless` cannot be undone, so the
  /// selector hides the title bar and goes fullscreen on the window's monitor
  /// (the same monitor [WindowsScreenService] reports as the capture area).
  Future<void> _applyWindowsSelectorChrome() async {
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
  }

  Future<void> _frameless() async {
    if (Platform.isWindows) {
      return;
    }
    await _call('setAsFrameless', () => windowManager.setAsFrameless());
  }

  /// Leave fullscreen while still mapped, then shrink to the chip at opacity 0.
  ///
  /// Do not [windowManager.hide]: on Linux, hiding the only GTK window
  /// quits the Flutter process (`Lost connection to device`). Opacity 0
  /// and not always-on-top keep the GNOME screencast prompt usable.
  /// [showRecordingControls] reveals the chip after capture has started.
  Future<void> prepareRecordingChrome({Offset? position}) async {
    await _setOpaqueChrome();
    await _call('setAlwaysOnTop(false)', () => windowManager.setAlwaysOnTop(false));
    await _call('setOpacity(0)', () => windowManager.setOpacity(0));
    await _leaveFullscreen();
    await _frameless();
    await _call(
      'setTitleBarStyle(hidden)',
      () => windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
    );
    await _call('setSkipTaskbar(true)', () => windowManager.setSkipTaskbar(true));
    await _call('setResizable(true)', () => windowManager.setResizable(true));
    await _ensureChipSize(position ?? const Offset(24, 24));
    await _call('setResizable(false)', () => windowManager.setResizable(false));
    await _call('setTitle', () => windowManager.setTitle('Recording'));
    await _setBackground(opaqueBackground, 'opaque');
  }

  Future<void> showRecordingControls({
    required ScreenRegion captureRegion,
    required DesktopGeometry geometry,
  }) async {
    final position = await controlPosition(captureRegion) ?? const Offset(24, 24);
    await _call('setResizable(true)', () => windowManager.setResizable(true));
    await _shrinkToRecordingChip(position);
    await _call('setAlwaysOnTop(true)', () => windowManager.setAlwaysOnTop(true));
    await _call('setSkipTaskbar(false)', () => windowManager.setSkipTaskbar(false));
    await _call('show', () => windowManager.show());
    await _call('focus', () => windowManager.focus());
    await _ensureChipSize(position);
    await _call('setResizable(false)', () => windowManager.setResizable(false));
    await _call('setOpacity(1)', () => windowManager.setOpacity(1));
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

  Future<void> _leaveFullscreen() async {
    await _call('setFullScreen(false)', () => windowManager.setFullScreen(false));
    await _call('unmaximize', () => windowManager.unmaximize());
    for (var i = 0; i < 8; i++) {
      if (!await _isFullScreenOrMaximized()) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _call('setFullScreen(false)', () => windowManager.setFullScreen(false));
      await _call('unmaximize', () => windowManager.unmaximize());
    }
  }

  Future<bool> _isFullScreenOrMaximized() async {
    try {
      return await windowManager.isFullScreen() ||
          await windowManager.isMaximized();
    } on MissingPluginException {
      return false;
    } catch (error) {
      AppLogger.debug('Could not read fullscreen state: $error');
      return false;
    }
  }

  Rect _chipBounds(Offset position) {
    return Rect.fromLTWH(
      position.dx,
      position.dy,
      recordingSize.width,
      recordingSize.height,
    );
  }

  Future<void> _shrinkToRecordingChip(Offset position) async {
    await _call(
      'clearMaximumSize',
      () => windowManager.setMaximumSize(const Size(10000, 10000)),
    );
    await _call(
      'setMinimumSize(1x1)',
      () => windowManager.setMinimumSize(const Size(1, 1)),
    );
    final bounds = _chipBounds(position);
    await _nativeWindow.setFixedBounds(bounds);
    _windowOps.add('setFixedBounds(recording)');
    await _call(
      'setMinimumSize(recording)',
      () => windowManager.setMinimumSize(recordingSize),
    );
    await _call(
      'setMaximumSize(recording)',
      () => windowManager.setMaximumSize(recordingSize),
    );
    await _call('setBounds(recording)', () => windowManager.setBounds(bounds));
    await _call('setSize(recording)', () => windowManager.setSize(recordingSize));
    await _nativeWindow.setFixedBounds(bounds);
  }

  Future<void> _ensureChipSize(Offset position) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      if (attempt > 0) {
        await _leaveFullscreen();
        await _call('setResizable(true)', () => windowManager.setResizable(true));
      }
      await _shrinkToRecordingChip(position);
      final size = await _recordingWindowSize();
      if (size == null) {
        return;
      }
      AppLogger.info('Recording chrome size: ${size.width}x${size.height}');
      if (size.width <= recordingSize.width + 40 &&
          size.height <= recordingSize.height + 40) {
        return;
      }
      AppLogger.warn(
        'Recording window stayed large (${size.width}x${size.height}); retrying bounds',
      );
      await Future<void>.delayed(Duration(milliseconds: 50 * (attempt + 1)));
    }
  }

  Future<Size?> _recordingWindowSize() async {
    try {
      return await windowManager.getSize();
    } on MissingPluginException {
      return null;
    } catch (error) {
      AppLogger.debug('Could not verify recording chrome size: $error');
      return null;
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
