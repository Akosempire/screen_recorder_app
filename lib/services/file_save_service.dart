import 'dart:io';

import 'package:file_selector/file_selector.dart';

/// Native save dialog. Isolated so tests can inject a fake.
abstract class FileSaveService {
  Future<String?> chooseSaveLocation({
    String suggestedName,
    String? initialDirectory,
  });
}

class LinuxFileSaveService implements FileSaveService {
  const LinuxFileSaveService();

  @override
  Future<String?> chooseSaveLocation({
    String suggestedName = 'recording.mp4',
    String? initialDirectory,
  }) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      initialDirectory: initialDirectory,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'MP4 video', extensions: ['mp4']),
        XTypeGroup(label: 'Matroska video', extensions: ['mkv']),
      ],
    );
    return location?.path;
  }
}

/// Copies the produced recording to the path chosen by the user.
abstract class RecordingStorage {
  Future<void> persist(String sourcePath, String destinationPath);

  Future<bool> exists(String path);
}

class IoRecordingStorage implements RecordingStorage {
  const IoRecordingStorage();

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<void> persist(String sourcePath, String destinationPath) async {
    if (sourcePath == destinationPath) {
      return;
    }
    final dest = File(destinationPath);
    await dest.parent.create(recursive: true);
    try {
      await File(sourcePath).rename(destinationPath);
    } on FileSystemException {
      await File(sourcePath).copy(destinationPath);
    }
  }
}
