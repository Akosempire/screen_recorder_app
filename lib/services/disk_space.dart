import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'ffmpeg_process_manager.dart';

/// About how much disk an hour of screen recording takes (1080p, the app's
/// default quality). Used to turn free space into "hours of recording".
const int bytesPerRecordingHour = 1024 * 1024 * 1024;

/// Below this, recording asks first.
const int lowDiskBytes = 2 * 1024 * 1024 * 1024;

/// "820 MB", "3.4 GB".
String formatBytes(int bytes) {
  const kb = 1024, mb = kb * 1024, gb = mb * 1024;
  if (bytes >= gb) {
    final v = bytes / gb;
    return '${v >= 100 ? v.round() : v.toStringAsFixed(1)} GB';
  }
  if (bytes >= mb) return '${(bytes / mb).round()} MB';
  if (bytes >= kb) return '${(bytes / kb).round()} KB';
  return '$bytes B';
}

/// "about 3 hours", "about 40 minutes" of recording that fits in [bytes].
String recordingTimeFor(int bytes) {
  final minutes = (bytes / bytesPerRecordingHour * 60).floor();
  if (minutes < 1) return 'less than a minute';
  if (minutes < 90) return 'about $minutes minute${minutes == 1 ? '' : 's'}';
  final hours = (minutes / 60).floor();
  return 'about $hours hours';
}

/// Reads free bytes from `df -Pk` output (mac, Linux).
int? parseDfFree(String out) {
  final lines = out.trim().split('\n');
  if (lines.length < 2) return null;
  final cols = lines.last.trim().split(RegExp(r'\s+'));
  if (cols.length < 4) return null;
  final kb = int.tryParse(cols[3]);
  return kb == null ? null : kb * 1024;
}

/// Free space on the drive holding [path], or null if it can't be told.
Future<int?> freeDiskBytes(String path, {ProcessRunner runner = const ProcessRunner()}) async {
  try {
    if (Platform.isWindows) {
      final root = p.rootPrefix(p.absolute(path));
      final drive = root.isEmpty ? 'C:\\' : root;
      final result = await runner.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "[System.IO.DriveInfo]::new('${drive.replaceAll("'", "''")}').AvailableFreeSpace",
        ],
        timeout: const Duration(seconds: 10),
      );
      return int.tryParse('${result.stdout}'.trim());
    }
    final result = await runner.run('df', ['-Pk', path], timeout: const Duration(seconds: 10));
    if (result.exitCode != 0) return null;
    return parseDfFree('${result.stdout}');
  } catch (error) {
    AppLogger.debug('Free space check failed: $error');
    return null;
  }
}

/// Total size of the files under [dir].
Future<int> folderBytes(Directory dir) async {
  var total = 0;
  try {
    if (!await dir.exists()) return 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
  } catch (error) {
    AppLogger.debug('Could not measure ${dir.path}: $error');
  }
  return total;
}
