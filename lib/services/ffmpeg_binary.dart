import 'dart:io';

import 'package:path/path.dart' as p;

String? _cachedFfmpeg;

/// Path to the FFmpeg executable.
///
/// On Windows the installer ships `ffmpeg\ffmpeg.exe` next to the app, so
/// users never need to install FFmpeg or edit PATH. Elsewhere (and as a
/// Windows fallback for `flutter run`) plain `ffmpeg` from PATH is used.
String get ffmpegExecutable => _cachedFfmpeg ??= _resolveFfmpeg();

String _resolveFfmpeg() {
  if (!Platform.isWindows) {
    return 'ffmpeg';
  }
  final appDir = p.dirname(Platform.resolvedExecutable);
  final candidates = [
    p.join(appDir, 'ffmpeg', 'ffmpeg.exe'),
    p.join(appDir, 'ffmpeg.exe'),
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return 'ffmpeg';
}
