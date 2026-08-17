import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/recorder_exception.dart';
import '../models/screen_region.dart';
import 'app_logger.dart';
import 'ffmpeg_process_manager.dart';
import 'screen_recorder.dart';

class CaptureCommand {
  final String executable;
  final List<String> arguments;

  const CaptureCommand(this.executable, this.arguments);
}

/// Builds one capture command for a region and output path.
typedef CaptureCommandBuilder = CaptureCommand Function(
  ScreenRegion region,
  String outputPath,
);

/// Segment-based recorder used for both X11 (FFmpeg) and Wayland (wf-recorder).
///
/// Pause/resume strategy:
/// FFmpeg `x11grab` and `wf-recorder` do not provide a reliable, format-safe
/// pause that removes the paused interval from the timeline. Sending SIGSTOP
/// freezes timestamps incorrectly for MP4.
///
/// Instead, pause stops the current capture process (clean quit / SIGINT) and
/// resume starts a new segment with identical encoding settings. Stop merges
/// segments with FFmpeg concat. The paused wall-clock time is omitted from
/// the final video.
class SegmentingScreenRecorder implements ScreenRecorder {
  SegmentingScreenRecorder({
    required this.backendName,
    required CaptureCommandBuilder commandBuilder,
    required StopStyle stopStyle,
    CaptureProcessManager? processManager,
    ProcessRunner? runner,
    this.encoder = 'libx264',
  })  : _commandBuilder = commandBuilder,
        _stopStyle = stopStyle,
        _process = processManager ?? CaptureProcessManager(runner: runner ?? const ProcessRunner()),
        _runner = runner ?? const ProcessRunner();

  @override
  final String backendName;

  final CaptureCommandBuilder _commandBuilder;
  final StopStyle _stopStyle;
  final CaptureProcessManager _process;
  final ProcessRunner _runner;
  final String encoder;

  Directory? _sessionDir;
  final List<String> _segments = [];
  ScreenRegion? _region;
  bool _paused = false;
  bool _unexpectedExit = false;
  String? _unexpectedDetails;

  @override
  bool get isRecording => _process.isRunning || (_paused && _segments.isNotEmpty);

  @override
  Future<void> start(ScreenRegion region) async {
    if (!region.isValid) {
      throw RecorderException(
        userMessage:
            'The selected region is too small. Choose at least ${ScreenRegion.minWidth}×${ScreenRegion.minHeight} pixels.',
        technicalDetails: region.toString(),
      );
    }
    _region = region.evenAligned();
    _paused = false;
    _unexpectedExit = false;
    _unexpectedDetails = null;
    _segments.clear();
    _sessionDir = await Directory.systemTemp.createTemp('screen_recorder_');
    AppLogger.info('Recording session dir: ${_sessionDir!.path}');
    try {
      await _startSegment();
    } catch (_) {
      await _process.stop(style: _stopStyle, timeout: const Duration(seconds: 2));
      rethrow;
    }
  }

  @override
  Future<void> pause() async {
    if (_paused) {
      return;
    }
    if (!_process.isRunning) {
      throw const RecorderException(userMessage: 'Nothing is recording to pause.');
    }
    await _stopCurrentSegment();
    _paused = true;
    AppLogger.info('Recording paused (${_segments.length} segment(s))');
  }

  @override
  Future<void> resume() async {
    if (!_paused) {
      return;
    }
    if (_region == null) {
      throw const RecorderException(userMessage: 'Cannot resume without a region.');
    }
    _paused = false;
    await _startSegment();
    AppLogger.info('Recording resumed');
  }

  @override
  Future<String?> stop() async {
    if (_process.isRunning) {
      await _stopCurrentSegment();
    }
    _paused = false;
    final dir = _sessionDir;
    final segments = List<String>.from(_segments);
    _segments.clear();
    _sessionDir = null;
    _region = null;

    if (segments.isEmpty) {
      if (_unexpectedExit) {
        throw RecorderException(
          userMessage: 'Recording stopped unexpectedly. Nothing was saved.',
          technicalDetails: _unexpectedDetails,
        );
      }
      return null;
    }

    if (segments.length == 1) {
      return segments.first;
    }

    if (dir == null) {
      return segments.last;
    }
    final merged = p.join(dir.path, 'merged.mp4');
    await _mergeSegments(segments, merged, dir.path);
    return merged;
  }

  Future<void> _startSegment() async {
    if (_unexpectedExit) {
      throw RecorderException(
        userMessage: 'The capture process exited unexpectedly.',
        technicalDetails: _unexpectedDetails,
      );
    }
    final region = _region;
    final dir = _sessionDir;
    if (region == null || dir == null) {
      throw const RecorderException(userMessage: 'Recording session is not initialized.');
    }

    final index = _segments.length;
    final output = p.join(dir.path, 'segment_$index.mp4');
    final command = _commandBuilder(region, output);
    await _process.start(
      executable: command.executable,
      arguments: command.arguments,
      onExited: (code) {
        if (code != 0 && code != 255) {
          _unexpectedExit = true;
          _unexpectedDetails = _process.stderrText;
          AppLogger.error(
            'Capture process exited with $code',
            _process.stderrText,
          );
        }
      },
    );

    // Give FFmpeg a moment to fail fast (missing encoder, bad display, etc.).
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (_unexpectedExit) {
      throw RecorderException(
        userMessage: _friendlyStartError(_process.stderrText),
        technicalDetails: _process.stderrText,
      );
    }
    _segments.add(output);
  }

  Future<void> _stopCurrentSegment() async {
    final code = await _process.stop(style: _stopStyle);
    final stderr = _process.stderrText;
    if (_unexpectedExit) {
      throw RecorderException(
        userMessage: _friendlyStartError(stderr),
        technicalDetails: stderr,
      );
    }
    if (code != 0 && code != 255 && !_looksLikeCleanStop(stderr)) {
      AppLogger.warn('Capture stop exit code $code: $stderr');
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  Future<void> _mergeSegments(
    List<String> segments,
    String outputPath,
    String sessionDir,
  ) {
    return mergeMediaSegments(
      segments: segments,
      outputPath: outputPath,
      encoder: encoder,
      runner: _runner,
      sessionDir: sessionDir,
    );
  }

  String _friendlyStartError(String stderr) {
    final lower = stderr.toLowerCase();
    if (lower.contains('wlr-screencopy')) {
      return 'This desktop does not support wf-recorder. GNOME/KDE Wayland need the GNOME screencast service instead.';
    }
    if (lower.contains('no such file') || lower.contains('not found')) {
      return 'The capture tool failed to start. Check that FFmpeg is installed.';
    }
    if (lower.contains('permission') || lower.contains('operation not permitted')) {
      return 'Screen capture was denied. Check display permissions.';
    }
    if (lower.contains('connection refused') ||
        lower.contains('cannot open display') ||
        lower.contains('no protocol specified')) {
      return 'Could not connect to the display server. Check DISPLAY / Wayland permissions.';
    }
    if (lower.contains('no space') || lower.contains('enospc')) {
      return 'Not enough disk space to record.';
    }
    if (lower.contains('unknown encoder') || lower.contains('encoder not found')) {
      return 'FFmpeg is missing a required video encoder (libx264).';
    }
    if (lower.contains('invalid') && lower.contains('size')) {
      return 'The selected region is not valid for the capture backend.';
    }
    return 'Screen capture failed to start.';
  }

  bool _looksLikeCleanStop(String stderr) {
    final lower = stderr.toLowerCase();
    return lower.contains('exiting') ||
        lower.contains('trailer') ||
        lower.contains('muxing overhead');
  }
}

Future<void> mergeMediaSegments({
  required List<String> segments,
  required String outputPath,
  required String encoder,
  required ProcessRunner runner,
  required String sessionDir,
}) async {
  final listFile = File(p.join(sessionDir, 'concat.txt'));
  final buffer = StringBuffer();
  for (final segment in segments) {
    final escaped = segment.replaceAll("'", r"'\''");
    buffer.writeln("file '$escaped'");
  }
  await listFile.writeAsString(buffer.toString());

  AppLogger.info('Merging ${segments.length} segments into $outputPath');
  var result = await runner.run('ffmpeg', [
    '-y',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    listFile.path,
    '-c',
    'copy',
    '-an',
    '-movflags',
    '+faststart',
    outputPath,
  ]);

  if (result.exitCode != 0) {
    AppLogger.warn('Lossless concat failed (${result.stderr}); re-encoding');
    result = await runner.run('ffmpeg', [
      '-y',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      listFile.path,
      '-c:v',
      encoder,
      '-preset',
      'veryfast',
      '-crf',
      '23',
      '-pix_fmt',
      'yuv420p',
      '-an',
      '-movflags',
      '+faststart',
      outputPath,
    ]);
  }

  if (result.exitCode != 0) {
    throw RecorderException(
      userMessage: 'Could not merge paused recording segments.',
      technicalDetails: result.stderr.toString(),
    );
  }
}

Future<void> transcodeToMp4({
  required String inputPath,
  required String outputPath,
  required String encoder,
  required ProcessRunner runner,
}) async {
  if (p.extension(inputPath).toLowerCase() == '.mp4' && inputPath == outputPath) {
    return;
  }

  // GNOME 46+ writes fragmented MP4. Remux when possible so timestamps
  // and duration survive; re-encode WebM / broken containers.
  if (p.extension(inputPath).toLowerCase() == '.mp4') {
    final remux = await runner.run('ffmpeg', [
      '-y',
      '-i',
      inputPath,
      '-c',
      'copy',
      '-an',
      '-movflags',
      '+faststart',
      outputPath,
    ]);
    if (remux.exitCode == 0) {
      return;
    }
    AppLogger.warn('MP4 remux failed (${remux.stderr}); re-encoding');
  }

  final result = await runner.run('ffmpeg', [
    '-y',
    '-fflags',
    '+genpts',
    '-i',
    inputPath,
    '-c:v',
    encoder,
    '-preset',
    'veryfast',
    '-crf',
    '23',
    '-pix_fmt',
    'yuv420p',
    '-an',
    '-movflags',
    '+faststart',
    outputPath,
  ]);
  if (result.exitCode != 0) {
    throw RecorderException(
      userMessage: 'Could not convert the recording to MP4.',
      technicalDetails: result.stderr.toString(),
    );
  }
}

List<String> ffmpegEncodeArgs({
  required String encoder,
  required String outputPath,
}) {
  return [
    '-an',
    '-c:v',
    encoder,
    '-preset',
    encoder == 'mpeg4' ? 'fast' : 'veryfast',
    if (encoder != 'mpeg4') ...['-crf', '23'],
    '-pix_fmt',
    'yuv420p',
    '-movflags',
    '+faststart',
    outputPath,
  ];
}

List<String> buildX11GrabArgs({
  required ScreenRegion region,
  required String display,
  required String outputPath,
  required String encoder,
  int fps = 30,
}) {
  final aligned = region.evenAligned();
  return [
    '-y',
    '-f',
    'x11grab',
    '-video_size',
    '${aligned.width}x${aligned.height}',
    '-framerate',
    '$fps',
    '-draw_mouse',
    '1',
    '-i',
    '$display+${aligned.x},${aligned.y}',
    ...ffmpegEncodeArgs(encoder: encoder, outputPath: outputPath),
  ];
}

List<String> buildWfRecorderArgs({
  required ScreenRegion region,
  required String outputPath,
  int fps = 30,
}) {
  final aligned = region.evenAligned();
  return [
    '-g',
    '${aligned.x},${aligned.y} ${aligned.width}x${aligned.height}',
    '-r',
    '$fps',
    '-f',
    outputPath,
  ];
}
