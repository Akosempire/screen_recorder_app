import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/services/disk_space.dart';
import 'package:screen_recorder_app/services/mic_check.dart';
import 'package:screen_recorder_app/services/processing_status.dart';
import 'package:screen_recorder_app/services/recording_background.dart';
import 'package:screen_recorder_app/services/recording_edit.dart';
import 'package:screen_recorder_app/services/studio_save_service.dart';
import 'package:screen_recorder_app/services/time_estimate.dart';

void main() {
  group('time estimates', () {
    test('a 2-hour class: auto-zoom takes long, and says so', () {
      final r = estimateRedraw(const Duration(hours: 2), RedrawKind.autoZoom);
      expect(r.low, const Duration(minutes: 48));
      expect(r.high, const Duration(hours: 2, minutes: 12));
      expect(approxRange(r), '48 min–2.2 h');
    });

    test('short exports are quick; smaller videos are quicker', () {
      expect(approxRange(estimateRedraw(const Duration(seconds: 90), RedrawKind.export)), 'under a minute');
      final hd = estimateRedraw(const Duration(minutes: 30), RedrawKind.export);
      final sd = estimateRedraw(const Duration(minutes: 30), RedrawKind.export, height: 720);
      expect(sd.high, hd.high ~/ 2);
      expect(approxRange(hd), '5–15 min');
    });

    test('plain words for durations', () {
      expect(approxDuration(const Duration(seconds: 20)), 'under a minute');
      expect(approxDuration(const Duration(minutes: 4, seconds: 10)), 'about 4 min');
      expect(approxDuration(const Duration(hours: 1, minutes: 21)), 'about 1 h 20 min');
      expect(approxDuration(const Duration(hours: 2, minutes: 58)), 'about 3 h');
    });

    test('time left appears once it can be told', () {
      expect(timeLeft(const Duration(seconds: 1), 0.5), isNull, reason: 'too early');
      expect(timeLeft(const Duration(minutes: 1), 0.01), isNull, reason: 'too little done');
      expect(timeLeft(const Duration(minutes: 2), 0.25), const Duration(minutes: 6));
      final started = DateTime(2026, 1, 1, 10);
      final clock = ProgressClock(started: started)..update(0.5, now: started.add(const Duration(minutes: 3)));
      expect(clock.label, '50% · about 3 min left');
    });
  });

  group('exports', () {
    ExportSettings settings() => ExportSettings(fileName: 'x', folder: '/tmp');

    test('no changes: copied, instant', () {
      expect(exportRedraws(settings(), height: 1080, hasAudio: true), isFalse);
      expect(exportRedraws(settings()..keepSound = false, height: 1080, hasAudio: true), isFalse);
    });

    test('trims, background, quality or size: every frame is redrawn', () {
      expect(exportRedraws(settings()..segments = [const EditRange(2, 30)], height: 1080, hasAudio: true), isTrue);
      expect(exportRedraws(settings()..quality = ExportQuality.smaller, height: 1080, hasAudio: true), isTrue);
      expect(exportRedraws(settings()..resolution = ExportResolution.values.last, height: 2160, hasAudio: true), isTrue);
      expect(
        exportRedraws(settings()..background = const BackgroundSpec(kind: BackgroundKind.color, color: 0xFF336699), height: 1080, hasAudio: true),
        isTrue,
      );
    });

    test('the estimate uses the length that is kept', () {
      final s = settings()..segments = [const EditRange(0, 60), const EditRange(120, 180)];
      expect(exportLength(s, const Duration(hours: 1)), const Duration(minutes: 2));
      expect(exportLength(settings(), const Duration(hours: 1)), const Duration(hours: 1));
    });
  });

  test('background work is tracked so closing can warn', () async {
    final work = BackgroundWork.instance;
    expect(work.active, isFalse);
    late void Function(double) report;
    final done = work.track('Auto-zoom', (r) async {
      report = r;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return true;
    });
    expect(work.active, isTrue);
    report(0.42);
    expect(work.labels, ['Auto-zoom (42% done)']);
    expect(await done, isTrue);
    expect(work.active, isFalse);
  });

  group('disk space', () {
    test('df output', () {
      const out = 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
          '/dev/sda1 488245288 401234567 62386024 87% /\n';
      expect(parseDfFree(out), 62386024 * 1024);
      expect(parseDfFree('nonsense'), isNull);
    });

    test('plain sizes and how much recording fits', () {
      expect(formatBytes(3 * 1024 * 1024 * 1024 + 400 * 1024 * 1024), '3.4 GB');
      expect(formatBytes(820 * 1024 * 1024), '820 MB');
      expect(recordingTimeFor(bytesPerRecordingHour ~/ 2), 'about 30 minutes');
      expect(recordingTimeFor(bytesPerRecordingHour * 5), 'about 5 hours');
    });
  });

  group('microphone check', () {
    test('reads volumedetect', () {
      const err = '[Parsed_volumedetect_0 @ 0x1] mean_volume: -38.4 dB\n[Parsed_volumedetect_0 @ 0x1] max_volume: -12.0 dB\n';
      final v = parseVolumeDetect(err);
      expect(v.mean, -38.4);
      expect(v.max, -12.0);
      expect(parseVolumeDetect('max_volume: -inf dB').max, -999);
    });

    test('good, quiet, silent', () {
      expect(classifyMic(-12, -38), MicLevel.good);
      expect(classifyMic(-33, -55), MicLevel.quiet);
      expect(classifyMic(-80, -91), MicLevel.silent);
      expect(classifyMic(-999, -999), MicLevel.silent);
      expect(classifyMic(null, null), MicLevel.unavailable);
    });
  });
}
