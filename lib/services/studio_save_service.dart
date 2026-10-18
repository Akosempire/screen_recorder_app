import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../controllers/recording_controller.dart';
import '../screens/export_dialog.dart';
import 'app_logger.dart';
import 'ffmpeg_binary.dart';
import 'ffmpeg_process_manager.dart';
import 'file_save_service.dart';
import 'recording_library.dart';

enum ExportResolution {
  original('Original'),
  p1080('1080p'),
  p720('720p');

  const ExportResolution(this.label);
  final String label;

  int? get height => switch (this) {
        ExportResolution.original => null,
        ExportResolution.p1080 => 1080,
        ExportResolution.p720 => 720,
      };
}

enum ExportFrameRate {
  original('Original (30 fps)'),
  fps15('15 fps · smaller file');

  const ExportFrameRate(this.label);
  final String label;
}

enum ExportQuality {
  balanced('Balanced', null),
  high('High', 18),
  smaller('Smaller file', 28);

  const ExportQuality(this.label, this.crf);
  final String label;
  final int? crf;
}

class ExportSettings {
  ExportSettings({
    required this.fileName,
    required this.folder,
    this.resolution = ExportResolution.original,
    this.frameRate = ExportFrameRate.original,
    this.quality = ExportQuality.balanced,
    this.keepSound = true,
  });

  String fileName;
  String folder;
  ExportResolution resolution;
  ExportFrameRate frameRate;
  ExportQuality quality;
  bool keepSound;
}

/// Size of the output for [resolution] given a [width]×[height] source.
/// Never upscales.
(int, int) exportOutputSize(int width, int height, ExportResolution resolution) {
  final target = resolution.height;
  if (target == null || height <= target || height <= 0) {
    return (width, height);
  }
  final scaledWidth = ((width * target / height) / 2).round() * 2;
  return (scaledWidth, target);
}

/// FFmpeg arguments that apply [settings] to [source], or null when the file
/// can be kept exactly as it is.
List<String>? buildExportArgs({
  required String source,
  required String output,
  required ExportSettings settings,
  required int height,
  required bool hasAudio,
}) {
  final scale = settings.resolution.height != null &&
      height > settings.resolution.height!;
  final fps = settings.frameRate == ExportFrameRate.fps15;
  final crf = settings.quality.crf;
  final dropSound = hasAudio && !settings.keepSound;
  final reencode = scale || fps || crf != null;
  if (!reencode && !dropSound) {
    return null;
  }
  final filters = [
    if (scale) 'scale=-2:${settings.resolution.height}:flags=lanczos',
    if (fps) 'fps=15',
  ];
  return [
    '-y',
    '-hide_banner',
    '-i',
    source,
    if (filters.isNotEmpty) ...['-vf', filters.join(',')],
    if (reencode) ...[
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '${crf ?? 22}',
      '-pix_fmt',
      'yuv420p',
    ] else ...['-c:v', 'copy'],
    if (!hasAudio || dropSound) '-an' else ...['-c:a', 'copy'],
    '-movflags',
    '+faststart',
    output,
  ];
}

/// Picks a free path: `name.mp4`, `name (2).mp4`, …
String uniqueDestination(String folder, String fileName) {
  var base = fileName.trim();
  if (base.isEmpty) base = 'recording';
  base = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  if (p.extension(base).toLowerCase() == '.mp4') {
    base = p.basenameWithoutExtension(base);
  }
  var candidate = p.join(folder, '$base.mp4');
  var n = 2;
  while (File(candidate).existsSync()) {
    candidate = p.join(folder, '$base ($n).mp4');
    n++;
  }
  return candidate;
}

String defaultVideosFolder() {
  final home = Platform.isWindows
      ? Platform.environment['USERPROFILE']
      : Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    return Directory.systemTemp.path;
  }
  final videos = p.join(home, 'Videos');
  return Directory(videos).existsSync() ? videos : home;
}

/// Save flow for the studio UI: shows the in-app Export dialog, applies the
/// chosen settings with FFmpeg, and returns the destination path.
///
/// Falls back to the plain native save dialog when no UI is mounted.
class StudioSaveService implements FileSaveService {
  StudioSaveService({
    required this.navigatorKey,
    FileSaveService fallback = const LinuxFileSaveService(),
    this.runner = const ProcessRunner(),
  }) : _fallback = fallback;

  final GlobalKey<NavigatorState> navigatorKey;
  final FileSaveService _fallback;
  final ProcessRunner runner;

  /// Restores the full window before the dialog opens (set by the shell).
  Future<void> Function()? beforePrompt;

  /// Provides the produced file, region, and microphone state.
  RecordingController? controller;

  @override
  Future<String?> chooseSaveLocation({
    String suggestedName = 'recording.mp4',
    String? initialDirectory,
  }) async {
    final source = controller?.pendingSavePath;
    if (source == null || navigatorKey.currentState == null) {
      return _fallback.chooseSaveLocation(
        suggestedName: suggestedName,
        initialDirectory: initialDirectory,
      );
    }

    await beforePrompt?.call();
    await WidgetsBinding.instance.endOfFrame;

    final region = controller?.region;
    final recording = RecordingLibrary.instance.ensure(
      path: source,
      width: region?.width ?? 0,
      height: region?.height ?? 0,
      duration: controller?.elapsed ?? Duration.zero,
      hasAudio: controller?.recordMicrophone ?? false,
    );
    unawaited(RecordingLibrary.instance.buildPreviews(recording));

    final settings = ExportSettings(
      fileName: p.basenameWithoutExtension(suggestedName),
      folder: initialDirectory ?? defaultVideosFolder(),
      keepSound: recording.hasAudio,
    );

    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      return null;
    }
    final destination = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x33000000),
      builder: (_) => ExportDialog(
        recording: recording,
        settings: settings,
        onExport: (chosen) => _export(source, recording, chosen),
      ),
    );
    if (destination != null) {
      RecordingLibrary.instance.markSaved(destination);
    }
    return destination;
  }

  Future<String> _export(
    String source,
    LastRecording recording,
    ExportSettings settings,
  ) async {
    await Directory(settings.folder).create(recursive: true);
    final destination = uniqueDestination(settings.folder, settings.fileName);
    final temp = p.join(p.dirname(source), 'export_${DateTime.now().millisecondsSinceEpoch}.mp4');
    final args = buildExportArgs(
      source: source,
      output: temp,
      settings: settings,
      height: recording.height,
      hasAudio: recording.hasAudio,
    );
    if (args != null) {
      AppLogger.info('Export: ffmpeg ${args.join(' ')}');
      final result = await runner.run(ffmpegExecutable, args);
      if (result.exitCode != 0 || !await File(temp).exists()) {
        throw ExportFailure(result.stderr.toString());
      }
      // Replace the produced file so the controller saves the new version.
      await File(source).delete();
      await File(temp).rename(source);
    }
    return destination;
  }
}

class ExportFailure implements Exception {
  ExportFailure(this.details);
  final String details;

  @override
  String toString() => 'Export failed: $details';
}
