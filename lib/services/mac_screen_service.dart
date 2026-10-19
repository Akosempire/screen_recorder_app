import 'package:screen_retriever/screen_retriever.dart';

import '../models/display_server.dart';
import '../models/recorder_exception.dart';
import 'app_logger.dart';

/// macOS: records the main display. Geometry is in real pixels
/// (points × backing scale), the space avfoundation captures in, so the
/// region selector maps straight onto it.
class MacScreenService {
  const MacScreenService();

  Future<DesktopGeometry> queryGeometry() async {
    Display display;
    try {
      display = await screenRetriever.getPrimaryDisplay();
    } catch (error) {
      throw RecorderException(
        userMessage: 'Could not read the display size.',
        technicalDetails: '$error',
      );
    }
    final monitor = macMonitorFromPoints(
      name: display.name ?? 'main',
      widthPoints: display.size.width,
      heightPoints: display.size.height,
      scale: (display.scaleFactor ?? 1).toDouble(),
    );
    AppLogger.info('Desktop geometry (macOS main display): $monitor');
    return DesktopGeometry.fromMonitors(
      displayServer: DisplayServer.macos,
      monitors: [monitor],
    );
  }
}

/// The main display in pixels, origin (0, 0).
MonitorInfo macMonitorFromPoints({
  required String name,
  required double widthPoints,
  required double heightPoints,
  required double scale,
}) {
  final s = scale <= 0 ? 1.0 : scale;
  return MonitorInfo(
    name: name,
    x: 0,
    y: 0,
    width: (widthPoints * s).round(),
    height: (heightPoints * s).round(),
    primary: true,
    scaleFactor: s,
  );
}
