import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/recorder_exception.dart';
import '../models/screen_region.dart';
import 'app_logger.dart';
import 'ffmpeg_binary.dart';
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
  bool recordMicrophone,
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
  bool _recordMicrophone = false;
  bool _paused = false;
  bool _unexpectedExit = false;
  String? _unexpectedDetails;

  @override
  bool get isRecording => _process.isRunning || (_paused && _segments.isNotEmpty);

  @override
  Future<void> start(
    ScreenRegion region, {
    bool recordMicrophone = false,
  }) async {
    if (!region.isValid) {
      throw RecorderException(
        userMessage:
            'The selected region is too small. Choose at least ${ScreenRegion.minWidth}×${ScreenRegion.minHeight} pixels.',
        technicalDetails: region.toString(),
      );
    }
    _region = region.evenAligned();
    _recordMicrophone = recordMicrophone;
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
    final recordMicrophone = _recordMicrophone;
    _segments.clear();
    _sessionDir = null;
    _region = null;
    _recordMicrophone = false;

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
    return _mergeSegments(
      segments,
      merged,
      dir.path,
      recordMicrophone: recordMicrophone,
    );
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
    final command = _commandBuilder(region, output, _recordMicrophone);
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

  Future<String> _mergeSegments(
    List<String> segments,
    String outputPath,
    String sessionDir, {
    required bool recordMicrophone,
  }) {
    return mergeMediaSegments(
      segments: segments,
      outputPath: outputPath,
      encoder: encoder,
      runner: _runner,
      sessionDir: sessionDir,
      recordMicrophone: recordMicrophone,
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
    if (_recordMicrophone &&
        (lower.contains('pulse') ||
            lower.contains('alsa') ||
            lower.contains('cannot open audio') ||
            lower.contains('no such device'))) {
      return 'Could not record the microphone. Check that a mic is available and PulseAudio or PipeWire is running.';
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

Future<String> mergeMediaSegments({
  required List<String> segments,
  required String outputPath,
  required String encoder,
  required ProcessRunner runner,
  required String sessionDir,
  bool recordMicrophone = false,
}) async {
  final listFile = File(p.join(sessionDir, 'concat.txt'));
  final buffer = StringBuffer();
  for (final segment in segments) {
    final escaped = segment.replaceAll("'", r"'\''");
    buffer.writeln("file '$escaped'");
  }
  await listFile.writeAsString(buffer.toString());

  AppLogger.info('Merging ${segments.length} segments into $outputPath');
  var result = await runner.run(
    ffmpegExecutable,
    ffmpegConcatCopyArgs(
      listPath: listFile.path,
      outputPath: outputPath,
      recordMicrophone: recordMicrophone,
    ),
  );

  if (result.exitCode == 0) {
    return outputPath;
  }

  AppLogger.warn('Lossless concat failed (${result.stderr}); re-encoding');
  // libx264 cannot be muxed into WebM; fall back to MP4 if we have to encode.
  final encodePath = _encodeOutputPath(outputPath, encoder);
  result = await runner.run(
    ffmpegExecutable,
    ffmpegConcatEncodeArgs(
      listPath: listFile.path,
      encoder: encoder,
      outputPath: encodePath,
      recordMicrophone: recordMicrophone,
    ),
  );

  if (result.exitCode != 0) {
    throw RecorderException(
      userMessage: 'Could not merge paused recording segments.',
      technicalDetails: result.stderr.toString(),
    );
  }
  return encodePath;
}

String _encodeOutputPath(String outputPath, String encoder) {
  final ext = p.extension(outputPath).toLowerCase();
  if (ext == '.mp4' || encoder == 'mpeg4') {
    return outputPath;
  }
  return p.setExtension(outputPath, '.mp4');
}

List<String> ffmpegConcatCopyArgs({
  required String listPath,
  required String outputPath,
  bool recordMicrophone = false,
}) {
  return [
    '-y',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    listPath,
    '-c',
    'copy',
    if (!recordMicrophone) '-an',
    outputPath,
  ];
}

List<String> ffmpegConcatEncodeArgs({
  required String listPath,
  required String encoder,
  required String outputPath,
  bool recordMicrophone = false,
}) {
  return [
    '-y',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    listPath,
    ...ffmpegEncodeArgs(
      encoder: encoder,
      outputPath: outputPath,
      recordMicrophone: recordMicrophone,
    ),
  ];
}

List<String> ffmpegEncodeArgs({
  required String encoder,
  required String outputPath,
  bool recordMicrophone = false,
}) {
  return [
    if (recordMicrophone) ...[
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      '-ac',
      '2',
    ] else
      '-an',
    '-c:v',
    encoder,
    '-preset',
    encoder == 'mpeg4' ? 'fast' : 'ultrafast',
    if (encoder != 'mpeg4') ...['-crf', '23', '-threads', '0'],
    '-pix_fmt',
    'yuv420p',
    outputPath,
  ];
}

List<String> buildX11GrabArgs({
  required ScreenRegion region,
  required String display,
  required String outputPath,
  required String encoder,
  int fps = 30,
  bool recordMicrophone = false,
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
    if (recordMicrophone) ...['-thread_queue_size', '512'],
    '-i',
    '$display+${aligned.x},${aligned.y}',
    if (recordMicrophone) ...[
      '-f',
      'pulse',
      '-thread_queue_size',
      '512',
      '-i',
      'default',
    ],
    ...ffmpegEncodeArgs(
      encoder: encoder,
      outputPath: outputPath,
      recordMicrophone: recordMicrophone,
    ),
  ];
}

List<String> buildWfRecorderArgs({
  required ScreenRegion region,
  required String outputPath,
  int fps = 30,
  bool recordMicrophone = false,
}) {
  final aligned = region.evenAligned();
  return [
    '-g',
    '${aligned.x},${aligned.y} ${aligned.width}x${aligned.height}',
    '-r',
    '$fps',
    if (recordMicrophone) '-a',
    '-f',
    outputPath,
  ];
}
