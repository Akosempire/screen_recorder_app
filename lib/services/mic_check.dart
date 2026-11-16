import 'dart:io';

import '../platform/macos_screen_recorder.dart';
import '../platform/windows_screen_recorder.dart';
import 'app_logger.dart';
import 'ffmpeg_binary.dart';
import 'ffmpeg_process_manager.dart';

enum MicLevel { good, quiet, silent, unavailable }

class MicCheck {
  const MicCheck(this.level, {this.maxDb, this.meanDb, this.device});
  final MicLevel level;
  final double? maxDb;
  final double? meanDb;
  final String? device;

  /// One plain sentence for the user.
  String get message => switch (level) {
        MicLevel.good => 'Your microphone sounds good${device == null ? '' : ' ($device)'}.',
        MicLevel.quiet => 'Your microphone is quiet. The app evens out your voice while recording, '
            'but for the clearest sound move closer or turn up the input volume in your sound settings.',
        MicLevel.silent => 'We heard nothing${device == null ? '' : ' from $device'}. '
            'Check the mic isn’t muted, that it’s the input chosen in your sound settings, '
            'and that Screen Recorder is allowed to use the microphone.',
        MicLevel.unavailable => 'Couldn’t open a microphone. Plug one in, or check that Screen Recorder '
            'is allowed to use it in your privacy settings.',
      };
}

/// Reads `max_volume` / `mean_volume` from FFmpeg's volumedetect output.
({double? max, double? mean}) parseVolumeDetect(String stderr) {
  double? read(String key) {
    final m = RegExp('$key: (-?[0-9.]+|-inf) dB').firstMatch(stderr);
    if (m == null) return null;
    return m.group(1) == '-inf' ? -999 : double.tryParse(m.group(1)!);
  }

  return (max: read('max_volume'), mean: read('mean_volume'));
}

/// Good / quiet / silent from the loudest moment of a few seconds of
/// speaking (the raw mic, before the app levels it).
MicLevel classifyMic(double? maxDb, double? meanDb) {
  if (maxDb == null) return MicLevel.unavailable;
  if (maxDb <= -50 || (meanDb != null && meanDb <= -75)) return MicLevel.silent;
  if (maxDb < -24) return MicLevel.quiet;
  return MicLevel.good;
}

/// Records [seconds] from the microphone the app records with and measures
/// how loud it is. Nothing is saved.
Future<MicCheck> checkMicrophone({ProcessRunner runner = const ProcessRunner(), int seconds = 3}) async {
  try {
    final List<String> input;
    String? device;
    if (Platform.isWindows) {
      device = await findDshowMicrophone(runner);
      if (device == null) return const MicCheck(MicLevel.unavailable);
      input = ['-f', 'dshow', '-i', 'audio=$device'];
    } else if (Platform.isMacOS) {
      final mics = (await listAvfoundationDevices(runner)).microphones;
      if (mics.isEmpty) return const MicCheck(MicLevel.unavailable);
      device = mics.first.name;
      input = ['-f', 'avfoundation', '-i', ':${mics.first.index}'];
    } else {
      input = ['-f', 'pulse', '-i', 'default'];
    }
    final result = await runner.run(
      ffmpegExecutable,
      ['-hide_banner', '-nostats', ...input, '-t', '$seconds', '-af', 'volumedetect', '-f', 'null', '-'],
      timeout: Duration(seconds: seconds + 12),
    );
    final v = parseVolumeDetect('${result.stderr}');
    AppLogger.info('Mic check: max ${v.max} dB, mean ${v.mean} dB');
    return MicCheck(classifyMic(v.max, v.mean), maxDb: v.max, meanDb: v.mean, device: device);
  } catch (error) {
    AppLogger.warn('Mic check failed: $error');
    return const MicCheck(MicLevel.unavailable);
  }
}
