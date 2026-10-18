import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'ffmpeg_binary.dart';
import 'ffmpeg_process_manager.dart';

/// The most recent recording, with preview images for the home screen.
class LastRecording {
  LastRecording({
    required this.finalPath,
    required this.width,
    required this.height,
    required this.duration,
    required this.hasAudio,
    this.originalPath,
    this.focusSeconds,
  });

  /// Video that will be saved (auto-zoomed when zoom applied).
  final String finalPath;

  /// Pre-zoom video, when auto-zoom produced a separate file.
  final String? originalPath;

  /// A moment that shows the zoom well (shortly after the first click).
  final double? focusSeconds;

  final int width;
  final int height;
  final Duration duration;
  final bool hasAudio;

  File? beforeImage;
  File? afterImage;
  File? filmstrip;
  String? savedPath;

  bool get hasComparison =>
      originalPath != null && beforeImage != null && afterImage != null;

  String get title {
    final path = savedPath ?? finalPath;
    return p.basenameWithoutExtension(path);
  }

  String get summary {
    final secs = duration.inSeconds;
    final length = secs < 60
        ? '$secs second${secs == 1 ? '' : 's'}'
        : '${secs ~/ 60} min ${secs % 60} s';
    return '$width × $height, $length';
  }
}

/// Holds the last recording and builds its preview images with FFmpeg.
class RecordingLibrary extends ChangeNotifier {
  RecordingLibrary._();

  static final RecordingLibrary instance = RecordingLibrary._();

  LastRecording? _last;
  ProcessRunner runner = const ProcessRunner();

  LastRecording? get last => _last;

  /// Called by a recorder when it finishes producing a file.
  void register(LastRecording recording) {
    _last = recording;
    notifyListeners();
  }

  /// Ensures [path] is the current entry, creating a basic one if needed.
  LastRecording ensure({
    required String path,
    required int width,
    required int height,
    required Duration duration,
    required bool hasAudio,
  }) {
    final current = _last;
    if (current != null && current.finalPath == path) {
      return current;
    }
    final created = LastRecording(
      finalPath: path,
      width: width,
      height: height,
      duration: duration,
      hasAudio: hasAudio,
    );
    _last = created;
    notifyListeners();
    return created;
  }

  void markSaved(String path) {
    final current = _last;
    if (current == null) return;
    current.savedPath = path;
    notifyListeners();
  }

  /// Builds before/after stills and a filmstrip. Failures are non-fatal.
  Future<void> buildPreviews(LastRecording recording) async {
    final dir = p.dirname(recording.finalPath);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final seconds = recording.duration.inMilliseconds / 1000.0;
    final at = (recording.focusSeconds ??
            (seconds > 0 ? seconds * 0.35 : 0.0))
        .clamp(0.0, seconds > 0.2 ? seconds - 0.2 : 0.0);

    recording.afterImage = await _still(
      recording.finalPath,
      at,
      p.join(dir, 'preview_after_$stamp.png'),
    );
    final original = recording.originalPath;
    if (original != null) {
      recording.beforeImage = await _still(
        original,
        at,
        p.join(dir, 'preview_before_$stamp.png'),
      );
    }
    recording.filmstrip = await _filmstrip(
      recording.finalPath,
      seconds,
      p.join(dir, 'preview_strip_$stamp.png'),
    );
    notifyListeners();
  }

  final Map<String, File> _frames = {};

  /// A still of [recording] at [seconds] (for scrubbing in the editor).
  /// Cached per tenth of a second; null if FFmpeg can't read that moment.
  Future<File?> frameAt(LastRecording recording, double seconds) async {
    final key = '${recording.finalPath}@${(seconds * 10).round()}';
    final cached = _frames[key];
    if (cached != null && cached.existsSync()) return cached;
    final out = p.join(
      p.dirname(recording.finalPath),
      'frame_${recording.finalPath.hashCode.abs()}_${(seconds * 10).round()}.jpg',
    );
    final file = await _still(recording.finalPath, seconds, out, width: 960);
    if (file != null) _frames[key] = file;
    return file;
  }

  Future<File?> _still(String video, double at, String out, {int width = 1280}) async {
    try {
      final result = await runner.run(
        ffmpegExecutable,
        [
          '-y',
          '-hide_banner',
          '-ss',
          at.toStringAsFixed(2),
          '-i',
          video,
          '-frames:v',
          '1',
          '-vf',
          'scale=$width:-2',
          out,
        ],
        timeout: const Duration(seconds: 20),
      );
      final file = File(out);
      if (result.exitCode == 0 && await file.exists()) {
        return file;
      }
      AppLogger.debug('Preview still failed: ${result.stderr}');
    } catch (error) {
      AppLogger.debug('Preview still failed: $error');
    }
    return null;
  }

  Future<File?> _filmstrip(String video, double seconds, String out) async {
    if (seconds <= 0) return null;
    const tiles = 16;
    final rate = (tiles / seconds).clamp(0.01, 30.0);
    try {
      final result = await runner.run(
        ffmpegExecutable,
        [
          '-y',
          '-hide_banner',
          '-i',
          video,
          '-vf',
          'fps=${rate.toStringAsFixed(4)},scale=-2:72,tile=${tiles}x1',
          '-frames:v',
          '1',
          out,
        ],
        timeout: const Duration(seconds: 60),
      );
      final file = File(out);
      if (result.exitCode == 0 && await file.exists()) {
        return file;
      }
      AppLogger.debug('Filmstrip failed: ${result.stderr}');
    } catch (error) {
      AppLogger.debug('Filmstrip failed: $error');
    }
    return null;
  }
}
