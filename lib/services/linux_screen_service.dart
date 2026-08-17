import 'dart:io';

import 'package:screen_retriever/screen_retriever.dart';

import '../models/display_server.dart';
import '../models/recorder_exception.dart';
import 'app_logger.dart';
import 'ffmpeg_process_manager.dart';

/// Detects X11 vs Wayland and enumerates monitors in real desktop pixels.
class LinuxScreenService {
  LinuxScreenService({ProcessRunner runner = const ProcessRunner()})
      : _runner = runner;

  final ProcessRunner _runner;

  DisplayServer detectDisplayServer() {
    final session = Platform.environment['XDG_SESSION_TYPE']?.toLowerCase();
    if (session == 'wayland') {
      return DisplayServer.wayland;
    }
    if (session == 'x11') {
      return DisplayServer.x11;
    }
    if (Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty == true) {
      return DisplayServer.wayland;
    }
    if (Platform.environment['DISPLAY']?.isNotEmpty == true) {
      return DisplayServer.x11;
    }
    return DisplayServer.unknown;
  }

  String? displayName() {
    final display = Platform.environment['DISPLAY'];
    if (display == null || display.isEmpty) {
      return null;
    }
    return display;
  }

  Future<DesktopGeometry> queryGeometry() async {
    final server = detectDisplayServer();
    // On Wayland, xrandr talks to XWayland and is often a black/empty root.
    // Prefer GTK display metrics so overlay mapping matches the compositor.
    if (server == DisplayServer.wayland) {
      final flutterMonitors = await _queryScreenRetriever();
      if (flutterMonitors.isNotEmpty) {
        final geometry = DesktopGeometry.fromMonitors(
          displayServer: server,
          monitors: flutterMonitors,
          displayName: displayName(),
          waylandDisplay: Platform.environment['WAYLAND_DISPLAY'],
        );
        AppLogger.info('Desktop geometry (screen_retriever): $geometry');
        return geometry;
      }
    }

    final xrandrMonitors = await _queryXrandr();
    if (xrandrMonitors.isNotEmpty) {
      final geometry = DesktopGeometry.fromMonitors(
        displayServer: server,
        monitors: xrandrMonitors,
        displayName: displayName() ?? ':0.0',
        waylandDisplay: Platform.environment['WAYLAND_DISPLAY'],
      );
      AppLogger.info('Desktop geometry (xrandr): $geometry');
      return geometry;
    }

    final flutterMonitors = await _queryScreenRetriever();
    if (flutterMonitors.isNotEmpty) {
      final geometry = DesktopGeometry.fromMonitors(
        displayServer: server,
        monitors: flutterMonitors,
        displayName: displayName(),
        waylandDisplay: Platform.environment['WAYLAND_DISPLAY'],
      );
      AppLogger.info('Desktop geometry (screen_retriever): $geometry');
      return geometry;
    }

    throw const RecorderException(
      userMessage: 'Could not detect any monitors.',
      technicalDetails: 'xrandr and screen_retriever both returned nothing',
    );
  }

  Future<List<MonitorInfo>> _queryXrandr() async {
    try {
      final result = await _runner.run('xrandr', const ['--current']);
      if (result.exitCode != 0) {
        AppLogger.debug('xrandr failed: ${result.stderr}');
        return const [];
      }
      return parseXrandr(result.stdout.toString());
    } on ProcessException catch (error, stack) {
      AppLogger.debug('xrandr not available: $error\n$stack');
      return const [];
    }
  }

  Future<List<MonitorInfo>> _queryScreenRetriever() async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      return [
        for (var i = 0; i < displays.length; i++)
          MonitorInfo(
            name: displays[i].name ?? 'display-$i',
            x: (displays[i].visiblePosition?.dx ?? 0).round(),
            y: (displays[i].visiblePosition?.dy ?? 0).round(),
            width: displays[i].size.width.round(),
            height: displays[i].size.height.round(),
            primary: i == 0,
            scaleFactor: (displays[i].scaleFactor ?? 1).toDouble(),
          ),
      ];
    } catch (error, stack) {
      AppLogger.debug('screen_retriever failed: $error\n$stack');
      return const [];
    }
  }
}

/// Parses `xrandr --current` connected outputs, including negative offsets.
List<MonitorInfo> parseXrandr(String output) {
  final monitors = <MonitorInfo>[];
  final pattern = RegExp(
    r'^(\S+)\s+connected(?:\s+primary)?\s+(\d+)x(\d+)\+(-?\d+)\+(-?\d+)',
    multiLine: true,
  );
  for (final match in pattern.allMatches(output)) {
    monitors.add(
      MonitorInfo(
        name: match.group(1)!,
        width: int.parse(match.group(2)!),
        height: int.parse(match.group(3)!),
        x: int.parse(match.group(4)!),
        y: int.parse(match.group(5)!),
        primary: match.group(0)!.contains(' primary '),
      ),
    );
  }
  return monitors;
}
