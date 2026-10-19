import 'dart:io';

import 'package:path/path.dart' as p;

String? _cachedFfmpeg;

/// Path to the FFmpeg executable.
///
/// - Windows: the installer ships `ffmpeg\ffmpeg.exe` next to the app.
/// - macOS: the .app ships `Contents/MacOS/ffmpeg`. Apps opened from Finder
///   don't see the shell PATH, so Homebrew locations are checked too.
/// - Linux: the .deb depends on the distro's `ffmpeg`; plain `ffmpeg` from
///   PATH (or one placed next to the app in the .tar.gz).
String get ffmpegExecutable => _cachedFfmpeg ??= resolveFfmpeg(
      os: Platform.operatingSystem,
      appDir: p.dirname(Platform.resolvedExecutable),
      exists: (path) => File(path).existsSync(),
    );

/// Picks the FFmpeg to run (pure, for tests).
String resolveFfmpeg({
  required String os,
  required String appDir,
  required bool Function(String path) exists,
}) {
  final List<String> candidates;
  switch (os) {
    case 'windows':
      candidates = [
        p.join(appDir, 'ffmpeg', 'ffmpeg.exe'),
        p.join(appDir, 'ffmpeg.exe'),
      ];
    case 'macos':
      candidates = [
        p.join(appDir, 'ffmpeg'),
        p.join(p.dirname(appDir), 'Resources', 'ffmpeg'),
        '/opt/homebrew/bin/ffmpeg',
        '/usr/local/bin/ffmpeg',
      ];
    default:
      candidates = [
        p.join(appDir, 'ffmpeg'),
        p.join(appDir, 'lib', 'ffmpeg'),
      ];
  }
  for (final candidate in candidates) {
    if (exists(candidate)) return candidate;
  }
  return 'ffmpeg';
}
