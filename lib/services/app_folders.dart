import 'dart:io';

import 'package:path/path.dart' as p;

/// Where settings live:
/// - Windows: %APPDATA%\\screen_recorder_app
/// - macOS: ~/Library/Application Support/screen_recorder_app
/// - Linux: \$XDG_CONFIG_HOME (or ~/.config)/screen_recorder_app
Directory? appSettingsFolder({
  String? os,
  Map<String, String>? env,
}) {
  final system = os ?? Platform.operatingSystem;
  final e = env ?? Platform.environment;
  String? base;
  switch (system) {
    case 'windows':
      base = e['APPDATA'];
    case 'macos':
      final home = e['HOME'];
      base = home == null ? null : p.join(home, 'Library', 'Application Support');
    default:
      final xdg = e['XDG_CONFIG_HOME'];
      final home = e['HOME'];
      base = (xdg != null && xdg.isNotEmpty)
          ? xdg
          : (home == null ? null : p.join(home, '.config'));
  }
  if (base == null || base.isEmpty) return null;
  return Directory(p.join(base, 'screen_recorder_app'));
}

/// Default folder for saved videos: Videos (Windows/Linux) or Movies (macOS),
/// falling back to the home folder.
String defaultVideosFolderFor({String? os, Map<String, String>? env}) {
  final system = os ?? Platform.operatingSystem;
  final e = env ?? Platform.environment;
  final home = system == 'windows' ? e['USERPROFILE'] : e['HOME'];
  if (home == null || home.isEmpty) return Directory.systemTemp.path;
  final videos = p.join(home, system == 'macos' ? 'Movies' : 'Videos');
  return Directory(videos).existsSync() ? videos : home;
}

/// Opens the file manager with [file] selected (or its folder on Linux).
Future<void> revealInFileManager(String file) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,', file]);
    } else if (Platform.isMacOS) {
      await Process.start('open', ['-R', file]);
    } else {
      await Process.start('xdg-open', [p.dirname(file)]);
    }
  } catch (_) {}
}
