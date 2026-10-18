import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'controllers/recording_controller.dart';
import 'controllers/region_selection_controller.dart';
import 'models/display_server.dart';
import 'models/recorder_exception.dart';
import 'models/recording_state.dart';
import 'models/screen_region.dart';
import 'screens/home_screen.dart';
import 'screens/recording_screen.dart';
import 'screens/region_selection_screen.dart';
import 'services/app_logger.dart';
import 'services/last_save_path_store.dart';
import 'services/desktop_geometry.dart';
import 'services/native_window.dart';
import 'services/camera_bubble.dart';
import 'services/demo_mode.dart';
import 'services/recording_options.dart';
import 'services/screen_recorder.dart';
import 'services/screen_recorder_factory.dart';
import 'services/selector_backdrop.dart';
import 'services/studio_save_service.dart';
import 'services/shortcut_intents.dart';
import 'services/window_coordinator.dart';

class RecorderScope extends InheritedNotifier<RecordingController> {
  const RecorderScope({
    super.key,
    required RecordingController controller,
    required super.child,
  }) : super(notifier: controller);

  static RecordingController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<RecorderScope>();
    assert(scope != null, 'RecorderScope not found');
    return scope!.notifier!;
  }
}

/// Root navigator, used by the in-app Export dialog.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class ScreenRecorderApp extends StatelessWidget {
  const ScreenRecorderApp({
    super.key,
    this.controller,
    this.windowCoordinator,
    this.nativeWindow,
    this.manageWindows = true,
  });

  final RecordingController? controller;
  final WindowCoordinator? windowCoordinator;
  final NativeWindowService? nativeWindow;
  final bool manageWindows;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFE53935),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF121418),
    );

    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Screen Recorder',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: controller == null
          ? AppBootstrap(
              manageWindows: manageWindows,
              nativeWindow: nativeWindow,
            )
          : AppShell(
              controller: controller!,
              windowCoordinator: windowCoordinator ??
                  WindowCoordinator(nativeWindow: nativeWindow),
              nativeWindow: nativeWindow,
              manageWindows: manageWindows,
            ),
    );
  }
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({
    super.key,
    this.manageWindows = true,
    this.nativeWindow,
  });

  final bool manageWindows;
  final NativeWindowService? nativeWindow;

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  RecordingController? _controller;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final save = StudioSaveService(navigatorKey: appNavigatorKey);
    await RecordingOptions.instance.load();
    DemoMode.prepare();
    await CameraBubbleService.instance.refreshDevices();
    final lastSavePath = FileLastSavePathStore();
    try {
      final created = await ScreenRecorderFactory().create();
      final controller = RecordingController(
        recorder: created.recorder,
        fileSaveService: save,
        lastSavePathStore: lastSavePath,
        geometry: created.geometry,
      );
      save.controller = controller;
      if (!mounted) {
        return;
      }
      setState(() => _controller = controller);
    } catch (error, stack) {
      AppLogger.error('Startup failed', error, stack);
      final message = error is RecorderException
          ? error.userMessage
          : error is RecorderUnavailable
              ? error.message
              : 'Could not initialize screen capture.';
      final controller = RecordingController(
        recorder: UnsupportedRecorder(message),
        fileSaveService: save,
        lastSavePathStore: lastSavePath,
        geometry: await _geometryOrNull(),
      );
      controller.markStartupError(message);
      if (!mounted) {
        return;
      }
      setState(() {
        _controller = controller;
      });
    }
  }

  Future<DesktopGeometry?> _geometryOrNull() async {
    try {
      return await queryDesktopGeometry();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return AppShell(
      controller: _controller!,
      nativeWindow: widget.nativeWindow,
      windowCoordinator: WindowCoordinator(nativeWindow: widget.nativeWindow),
      manageWindows: widget.manageWindows,
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.controller,
    required this.windowCoordinator,
    this.nativeWindow,
    this.manageWindows = true,
  });

  final RecordingController controller;
  final WindowCoordinator windowCoordinator;
  final NativeWindowService? nativeWindow;
  final bool manageWindows;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  File? _snapshot;
  bool _busyWindow = false;
  bool _startingCapture = false;
  bool _restoringHome = false;
  final RegionSelectionController _selection = RegionSelectionController();
  late final NativeWindowService _nativeWindow;
  late final Future<AlphaProbe> _probeFuture;
  SelectorBackdrop _backdrop = SelectorBackdrop.snapshot;

  RecordingController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _nativeWindow = widget.nativeWindow ?? NativeWindowService();
    _probeFuture = _nativeWindow.probe();
    _controller.addListener(_rebuild);
    if (DemoMode.active) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => DemoMode.afterFirstFrame(appNavigatorKey),
      );
    }
    final save = _controller.fileSaveService;
    if (save is StudioSaveService) {
      save.controller ??= _controller;
      // The Export dialog needs the full window, not the recording chip.
      save.beforePrompt = widget.manageWindows
          ? () async {
              await widget.windowCoordinator.showHome();
              if (mounted) setState(() => _restoringHome = false);
            }
          : null;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_rebuild);
    _selection.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (!mounted) {
      return;
    }
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<void> _startSelection() async {
    if (_busyWindow) {
      return;
    }
    final state = _controller.state;
    if (state == RecordingState.selectingRegion ||
        state == RecordingState.ready) {
      return;
    }
    if (!_controller.canBeginSelection) {
      return;
    }
    _busyWindow = true;
    var entered = false;
    try {
      if (widget.manageWindows) {
        // Windows records the monitor the app is on, which can change
        // between recordings, so always re-query there.
        final geometry = Platform.isWindows
            ? await queryDesktopGeometry()
            : _controller.geometry ?? await queryDesktopGeometry();
        _controller.updateGeometry(geometry);
        final probe = await _probeFuture;
        _backdrop = chooseSelectorBackdrop(
          geometry: geometry,
          probe: probe,
        );
        _selection.keepRegionUntilDrag =
            _backdrop == SelectorBackdrop.liveHole;
        AppLogger.info('Selector backdrop: ${_backdrop.name}');
        _snapshot = await widget.windowCoordinator.enterSelection(
          geometry,
          backdrop: _backdrop,
        );
        entered = true;
      }
      _selection.clear();
      _controller.beginSelection();
      if (widget.manageWindows && entered) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          widget.windowCoordinator.revealSelector();
        });
      }
    } catch (error, stack) {
      AppLogger.error('Could not open region selector', error, stack);
      if (!mounted) {
        return;
      }
      _showSnack('Could not open the region selector.');
      if (widget.manageWindows) {
        await widget.windowCoordinator.showHome();
      }
    } finally {
      _busyWindow = false;
    }
  }

  Future<void> _cancelSelection() async {
    _controller.cancelSelection();
    if (widget.manageWindows) {
      await widget.windowCoordinator.showHome();
    }
  }

  Future<void> _confirmRecord(ScreenRegion region) async {
    if (_busyWindow) {
      return;
    }
    _controller.updateReadyRegion(region);
    if (!_controller.canStartRecording) {
      if (mounted) {
        _showSnack('Select a region of at least 100×100 pixels.');
      }
      return;
    }
    _busyWindow = true;
    try {
      final geometry = _controller.geometry;
      final captureRegion = _controller.region ?? region;
      if (mounted) {
        setState(() => _startingCapture = true);
      }
      if (widget.manageWindows) {
        await WidgetsBinding.instance.endOfFrame;
        await widget.windowCoordinator.prepareRecordingChrome(
          position: await widget.windowCoordinator.controlPosition(region),
        );
        await _controller.startRecording();
        if (geometry != null) {
          await widget.windowCoordinator.showRecordingControls(
            captureRegion: captureRegion,
            geometry: geometry,
          );
        }
      } else {
        await _controller.startRecording();
      }
    } catch (error, stack) {
      AppLogger.error('Failed to start capture', error, stack);
      _controller.recoverAfterFailure();
      if (widget.manageWindows) {
        await widget.windowCoordinator.showHome();
      }
    } finally {
      _busyWindow = false;
      if (mounted) {
        setState(() => _startingCapture = false);
      }
    }
  }

  void _confirmFromSelection() {
    final local = _selection.region;
    final geometry = _controller.geometry;
    if (local == null || geometry == null || !_selection.hasValidRegion) {
      return;
    }
    final region = geometry.mapOverlayRect(
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
    _confirmRecord(region);
  }

  Future<void> _togglePause() async {
    if (!_controller.canPause && !_controller.canResume) {
      return;
    }
    try {
      await _controller.togglePause();
    } catch (_) {}
  }

  Future<void> _stop() async {
    if (!_controller.canStop) {
      return;
    }
    if (mounted) {
      setState(() => _restoringHome = true);
    }
    try {
      await _controller.stopAndSave();
    } finally {
      if (widget.manageWindows) {
        await widget.windowCoordinator.showHome();
      }
      if (mounted) {
        setState(() => _restoringHome = false);
      }
    }
  }

  void _showSnack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return RecorderScope(
      controller: _controller,
      child: Shortcuts(
        shortcuts: AppShortcutMap.defaults,
        child: Actions(
          actions: {
            StartRecordingIntent: CallbackAction<StartRecordingIntent>(
              onInvoke: (_) {
                _startSelection();
                return null;
              },
            ),
            TogglePauseIntent: CallbackAction<TogglePauseIntent>(
              onInvoke: (_) {
                _togglePause();
                return null;
              },
            ),
            StopRecordingIntent: CallbackAction<StopRecordingIntent>(
              onInvoke: (_) {
                if (_controller.canStop) {
                  _stop();
                }
                return null;
              },
            ),
            CancelSelectionIntent: CallbackAction<CancelSelectionIntent>(
              onInvoke: (_) {
                if (state.canCancelSelection) {
                  _cancelSelection();
                }
                return null;
              },
            ),
            ConfirmRegionIntent: CallbackAction<ConfirmRegionIntent>(
              onInvoke: (_) {
                _confirmFromSelection();
                return null;
              },
            ),
          },
          child: Focus(
            autofocus: true,
            child: _body(state),
          ),
        ),
      ),
    );
  }

  Widget _body(RecordingState state) {
    if (_startingCapture ||
        (_restoringHome && state != RecordingState.saving) ||
        state.isActiveCapture ||
        state == RecordingState.stopping) {
      return RecordingScreen(
        controller: _controller,
        onPauseResume: _togglePause,
        onStop: _stop,
      );
    }

    if (state == RecordingState.selectingRegion ||
        state == RecordingState.ready) {
      final geometry = _controller.geometry;
      if (geometry == null) {
        return const Scaffold(
          body: Center(child: Text('No display geometry')),
        );
      }
      return RegionSelectionScreen(
        geometry: geometry,
        snapshot: _snapshot,
        selection: _selection,
        backdrop: _backdrop,
        nativeWindow: _nativeWindow,
        onCancel: _cancelSelection,
        onRecord: _confirmRecord,
        onRegionChanged: _controller.updateReadyRegion,
        recordMicrophone: _controller.recordMicrophone,
        onRecordMicrophoneChanged: _controller.setRecordMicrophone,
      );
    }

    return HomeScreen(
      controller: _controller,
      onStartRecording: _startSelection,
    );
  }
}
