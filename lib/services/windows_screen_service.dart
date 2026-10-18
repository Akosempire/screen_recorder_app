import 'package:flutter/services.dart';

import '../models/display_server.dart';
import '../models/recorder_exception.dart';
import '../platform/windows/win32_input.dart';
import 'app_logger.dart';
import 'cursor_overlay.dart';

/// Desktop layout on Windows, in physical pixels (the space gdigrab uses).
///
/// The capture area is the monitor the app window is on. The region
/// selector goes fullscreen on that same monitor, so overlay coordinates map
/// 1:1 onto it. To record another monitor, drag the app there first.
class WindowsScreenService {
  const WindowsScreenService({
    MethodChannel channel = const MethodChannel(CursorOverlay.channelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<DesktopGeometry> queryGeometry() async {
    final monitor = await _currentMonitor();
    if (monitor != null) {
      AppLogger.info('Desktop geometry (Win32 monitor): $monitor');
      return DesktopGeometry.fromMonitors(
        displayServer: DisplayServer.windows,
        monitors: [monitor],
      );
    }

    // Fallback (e.g. runner without the channel): primary monitor.
    final win32 = Win32Input.instance;
    if (win32 == null) {
      throw const RecorderException(
        userMessage: 'Windows capture is only available on Windows.',
      );
    }
    final (width, height) = win32.primarySize();
    if (width <= 0 || height <= 0) {
      throw const RecorderException(
        userMessage: 'Could not detect any monitors.',
        technicalDetails: 'GetSystemMetrics(SM_CXSCREEN) returned 0',
      );
    }
    AppLogger.info('Desktop geometry (Win32 primary): ${width}x$height');
    return DesktopGeometry.fromMonitors(
      displayServer: DisplayServer.windows,
      monitors: [
        MonitorInfo(
          name: 'primary',
          x: 0,
          y: 0,
          width: width,
          height: height,
          primary: true,
        ),
      ],
    );
  }

  Future<MonitorInfo?> _currentMonitor() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'getMonitorRect',
      );
      if (raw == null) return null;
      final width = raw['width'] as int? ?? 0;
      final height = raw['height'] as int? ?? 0;
      if (width <= 0 || height <= 0) return null;
      final x = raw['x'] as int? ?? 0;
      final y = raw['y'] as int? ?? 0;
      return MonitorInfo(
        name: 'monitor',
        x: x,
        y: y,
        width: width,
        height: height,
        primary: x == 0 && y == 0,
      );
    } on MissingPluginException {
      return null;
    } catch (error) {
      AppLogger.debug('getMonitorRect failed: $error');
      return null;
    }
  }
}
