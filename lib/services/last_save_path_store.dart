import 'dart:io';

import 'package:path/path.dart' as p;

/// Remembers the folder the user last saved a recording into.
abstract class LastSavePathStore {
  Future<String?> lastDirectory();

  Future<void> remember(String savedFilePath);
}

/// In-memory store for tests and as a fallback.
class MemoryLastSavePathStore implements LastSavePathStore {
  MemoryLastSavePathStore({String? initialDirectory})
      : _directory = initialDirectory;

  String? _directory;

  @override
  Future<String?> lastDirectory() async => _directory;

  @override
  Future<void> remember(String savedFilePath) async {
    final directory = p.dirname(savedFilePath);
    if (directory.isEmpty) {
      return;
    }
    _directory = directory;
  }
}

/// Persists the last save folder under XDG config so it survives restarts.
class FileLastSavePathStore implements LastSavePathStore {
  FileLastSavePathStore({Directory? configDir}) : _configDir = configDir;

  final Directory? _configDir;

  Directory get _dir {
    if (_configDir != null) {
      return _configDir;
    }
    final configHome = Platform.environment['XDG_CONFIG_HOME'];
    final base = (configHome != null && configHome.isNotEmpty)
        ? configHome
        : p.join(
            Platform.environment['HOME'] ?? Directory.systemTemp.path,
            '.config',
          );
    return Directory(p.join(base, 'screen_recorder_app'));
  }

  File get _file => File(p.join(_dir.path, 'last_save_directory'));

  @override
  Future<String?> lastDirectory() async {
    try {
      if (!await _file.exists()) {
        return null;
      }
      final value = (await _file.readAsString()).trim();
      if (value.isEmpty) {
        return null;
      }
      if (!await Directory(value).exists()) {
        return null;
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remember(String savedFilePath) async {
    final directory = p.dirname(savedFilePath);
    if (directory.isEmpty) {
      return;
    }
    try {
      await _dir.create(recursive: true);
      await _file.writeAsString(directory);
    } catch (_) {
      // Preference write failures must not fail the save itself.
    }
  }
}
