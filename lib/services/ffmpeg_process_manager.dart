import 'dart:async';
import 'dart:io';

import '../models/recorder_exception.dart';
import 'app_logger.dart';

class ProcessRunner {
  const ProcessRunner();

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    if (timeout == null) {
      return Process.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      );
    }

    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    final stdoutFuture =
        process.stdout.transform(systemEncoding.decoder).join();
    final stderrFuture =
        process.stderr.transform(systemEncoding.decoder).join();
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      return ProcessResult(
        process.pid,
        exitCode,
        await stdoutFuture,
        await stderrFuture,
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
      throw TimeoutException(
        'Timed out running $executable ${arguments.join(' ')}',
        timeout,
      );
    }
  }

  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
  }

  Future<bool> hasBinary(String executable) async {
    try {
      final which = await run('which', [executable]);
      if (which.exitCode == 0 && which.stdout.toString().trim().isNotEmpty) {
        return true;
      }
    } on ProcessException catch (error, stack) {
      AppLogger.debug('which $executable failed: $error\n$stack');
    }
    try {
      final result = await run(executable, const ['-version']);
      return result.exitCode == 0 ||
          result.exitCode == 1 ||
          result.exitCode == 255;
    } on ProcessException catch (error, stack) {
      AppLogger.debug('hasBinary($executable) failed: $error\n$stack');
      return false;
    }
  }
}

enum StopStyle {
  /// Write `q` to stdin (FFmpeg interactive stop).
  ffmpegQuit,

  /// SIGINT (wf-recorder and similar).
  sigint,
}

/// Owns a single capture subprocess. Arguments are always a list — never a shell string.
class CaptureProcessManager {
  CaptureProcessManager({ProcessRunner runner = const ProcessRunner()})
      : _runner = runner;

  final ProcessRunner _runner;
  Process? _process;
  final StringBuffer _stderr = StringBuffer();
  Future<int>? _exitCode;
  bool _stopping = false;

  bool get isRunning => _process != null;
  String get stderrText => _stderr.toString();

  void _clearProcess() {
    _process = null;
    _exitCode = null;
  }

  Future<void> start({
    required String executable,
    required List<String> arguments,
    String? workingDirectory,
    void Function(int exitCode)? onExited,
  }) async {
    if (_process != null) {
      AppLogger.warn('Stopping leftover capture process before starting another');
      await stop(style: StopStyle.sigint, timeout: const Duration(seconds: 2));
    }
    _stderr.clear();
    _stopping = false;
    AppLogger.info('Starting $executable ${arguments.join(' ')}');
    try {
      _process = await _runner.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (error, stack) {
      AppLogger.error('Failed to start $executable', error, stack);
      throw RecorderException(
        userMessage: 'Could not start $executable. Is it installed and on PATH?',
        technicalDetails: error.toString(),
      );
    }

    _process!.stdout.listen((_) {});
    _process!.stderr.listen((data) {
      final text = String.fromCharCodes(data);
      _stderr.write(text);
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) {
        AppLogger.debug(trimmed);
      }
    });

    _exitCode = _process!.exitCode.then((code) {
      AppLogger.info('$executable exited with code $code');
      if (!_stopping && onExited != null) {
        onExited(code);
      }
      _process = null;
      return code;
    });
  }

  Future<int> stop({
    StopStyle style = StopStyle.ffmpegQuit,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final process = _process;
    if (process == null) {
      return 0;
    }
    _stopping = true;
    try {
      switch (style) {
        case StopStyle.ffmpegQuit:
          try {
            process.stdin.write('q');
            await process.stdin.flush();
            await process.stdin.close();
          } catch (error, stack) {
            AppLogger.debug('FFmpeg stdin quit failed: $error\n$stack');
          }
        case StopStyle.sigint:
          process.kill(ProcessSignal.sigint);
      }

      final code = await _exitCode?.timeout(
        timeout,
        onTimeout: () async {
          AppLogger.warn('Capture process did not exit in time; sending SIGTERM');
          process.kill(ProcessSignal.sigterm);
          return _exitCode!.timeout(
            const Duration(seconds: 3),
            onTimeout: () async {
              AppLogger.warn('Capture process still running; sending SIGKILL');
              process.kill(ProcessSignal.sigkill);
              return _exitCode ?? Future.value(1);
            },
          );
        },
      );
      return code ?? 1;
    } finally {
      _clearProcess();
    }
  }
}

class FfmpegProbe {
  FfmpegProbe({ProcessRunner runner = const ProcessRunner()}) : _runner = runner;

  final ProcessRunner _runner;

  Future<bool> isAvailable() async {
    try {
      final result = await _runner.run('ffmpeg', const ['-version']);
      return result.exitCode == 0;
    } on ProcessException catch (error, stack) {
      AppLogger.debug('ffmpeg -version failed: $error\n$stack');
      return false;
    }
  }

  Future<String> versionSummary() async {
    try {
      final result = await _runner.run('ffmpeg', const ['-version']);
      final line = result.stdout.toString().split('\n').first.trim();
      return line.isEmpty ? 'ffmpeg' : line;
    } on ProcessException {
      return 'ffmpeg (unavailable)';
    }
  }

  Future<String> preferredVideoEncoder() async {
    try {
      final result = await _runner.run(
        'ffmpeg',
        const ['-hide_banner', '-encoders'],
      );
      final out = '${result.stdout}\n${result.stderr}';
      if (out.contains('libx264')) {
        return 'libx264';
      }
      if (out.contains('libopenh264')) {
        return 'libopenh264';
      }
      AppLogger.warn('libx264 not found; falling back to mpeg4');
      return 'mpeg4';
    } on ProcessException {
      return 'libx264';
    }
  }

  Future<bool> hasPipewireInput() async {
    try {
      final result = await _runner.run(
        'ffmpeg',
        const ['-hide_banner', '-devices'],
      );
      return '${result.stdout}\n${result.stderr}'.contains('pipewire');
    } on ProcessException {
      return false;
    }
  }
}
