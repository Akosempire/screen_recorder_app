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
import 'recording_background.dart';
import 'recording_library.dart';
import 'recording_options.dart';

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
    this.background = const BackgroundSpec(),
  });

  String fileName;
  String folder;
  ExportResolution resolution;
  ExportFrameRate frameRate;
  ExportQuality quality;
  bool keepSound;

  /// Background behind the recording (none by default).
  BackgroundSpec background;
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
///
/// With [background] and [backgroundFrame] (a PNG of the background with a
/// transparent rounded window, see `renderBackgroundFrame`), the recording is
/// scaled into the window and the frame is laid over it.
List<String>? buildExportArgs({
  required String source,
  required String output,
  required ExportSettings settings,
  required int height,
  required bool hasAudio,
  BackgroundLayout? background,
  String? backgroundFrame,
}) {
  final fps = settings.frameRate == ExportFrameRate.fps15;
  final crf = settings.quality.crf;
  final dropSound = hasAudio && !settings.keepSound;

  if (background != null && backgroundFrame != null) {
    final b = background;
    final graph = [
      '[0:v]scale=${b.innerWidth}:${b.innerHeight}:flags=lanczos,setsar=1,'
          'pad=${b.width}:${b.height}:${b.x}:${b.y}:color=black[rec]',
      '[rec][1:v]overlay=0:0:shortest=1${fps ? ',fps=15' : ''},format=yuv420p[out]',
    ].join(';');
    return [
      '-y',
      '-hide_banner',
      '-i',
      source,
      '-loop',
      '1',
      '-i',
      backgroundFrame,
      '-filter_complex',
      graph,
      '-map',
      '[out]',
      if (hasAudio && !dropSound) ...['-map', '0:a?', '-c:a', 'copy'] else '-an',
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '${crf ?? 20}',
      '-movflags',
      '+faststart',
      output,
    ];
  }

  final scale = settings.resolution.height != null &&
      height > settings.resolution.height!;
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
      background: RecordingOptions.instance.background,
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
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final temp = p.join(p.dirname(source), 'export_$stamp.mp4');

    BackgroundLayout? layout;
    String? framePath;
    if (settings.background.isActive) {
      final (w, h) = await _videoSize(source, recording);
      final (outW, outH) = exportOutputSize(w, h, settings.resolution);
      layout = layoutBackground(outW, outH, settings.background);
      framePath = p.join(p.dirname(source), 'background_$stamp.png');
      await File(framePath).writeAsBytes(
        await renderBackgroundFrame(layout, settings.background),
      );
    }

    try {
      final args = buildExportArgs(
        source: source,
        output: temp,
        settings: settings,
        height: recording.height,
        hasAudio: recording.hasAudio,
        background: layout,
        backgroundFrame: framePath,
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
    } finally {
      if (framePath != null) {
        try {
          await File(framePath).delete();
        } catch (_) {}
      }
    }
    return destination;
  }

  /// The real pixel size of [source] (FFmpeg's stream info), falling back to
  /// the size recorded for the region.
  Future<(int, int)> _videoSize(String source, LastRecording recording) async {
    try {
      final result = await runner.run(ffmpegExecutable, ['-hide_banner', '-i', source]);
      final size = parseVideoSize(result.stderr.toString());
      if (size != null) return size;
    } catch (_) {}
    return (
      recording.width > 0 ? recording.width : 1920,
      recording.height > 0 ? recording.height : 1080,
    );
  }
}

/// Reads "1920x1080" from the video stream line of `ffmpeg -i` output.
(int, int)? parseVideoSize(String ffmpegInfo) {
  for (final line in ffmpegInfo.split('\n')) {
    if (!line.contains('Video:')) continue;
    final m = RegExp(r'[ ,](\d{2,5})x(\d{2,5})[ ,\[]').firstMatch(line);
    if (m != null) return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }
  return null;
}

class ExportFailure implements Exception {
  ExportFailure(this.details);
  final String details;

  @override
  String toString() => 'Export failed: $details';
}
