import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/models/screen_region.dart';
import 'package:screen_recorder_app/platform/windows_screen_recorder.dart';

void main() {
  test('gdigrab arguments capture the region in physical pixels', () {
    const region = ScreenRegion(x: -1920, y: 101, width: 1281, height: 721);
    final args = buildGdigrabArgs(
      region: region,
      outputPath: r'C:\tmp\out.mp4',
      encoder: 'libx264',
    );
    expect(args, containsAllInOrder(['-f', 'gdigrab']));
    expect(args, containsAllInOrder(['-offset_x', '-1920']));
    expect(args, containsAllInOrder(['-offset_y', '101']));
    expect(args, containsAllInOrder(['-video_size', '1280x720']));
    expect(args, containsAllInOrder(['-i', 'desktop']));
    expect(args, contains('-an'));
    expect(args.contains('dshow'), isFalse);
    expect(args.last, r'C:\tmp\out.mp4');
  });

  test('gdigrab arguments add the DirectShow microphone', () {
    const region = ScreenRegion(x: 0, y: 0, width: 800, height: 600);
    final args = buildGdigrabArgs(
      region: region,
      outputPath: 'out.mp4',
      encoder: 'libx264',
      microphoneDevice: 'Microphone (Realtek(R) Audio)',
    );
    expect(args, containsAllInOrder(['-f', 'dshow']));
    expect(args, contains('audio=Microphone (Realtek(R) Audio)'));
    expect(args, containsAllInOrder(['-c:a', 'aac']));
    expect(args.contains('-an'), isFalse);
  });

  test('parses modern dshow device listing', () {
    const output = '''
[dshow @ 000001] "Integrated Camera" (video)
[dshow @ 000001]   Alternative name "@device_pnp_\\\\?\\usb#vid"
[dshow @ 000001] "Microphone Array (Realtek(R) Audio)" (audio)
[dshow @ 000001]   Alternative name "@device_cm_{33D9A762}\\wave_{ABC}"
[dshow @ 000001] "Headset Microphone (USB)" (audio)
''';
    expect(parseDshowAudioDevices(output), [
      'Microphone Array (Realtek(R) Audio)',
      'Headset Microphone (USB)',
    ]);
  });

  test('parses legacy dshow device listing', () {
    const output = '''
[dshow @ 0x1] DirectShow video devices (some may be both video and audio devices)
[dshow @ 0x1]  "Integrated Camera"
[dshow @ 0x1] DirectShow audio devices
[dshow @ 0x1]  "Microphone (USB Audio)"
[dshow @ 0x1]     Alternative name "@device_cm_{33D9A762}"
''';
    expect(parseDshowAudioDevices(output), ['Microphone (USB Audio)']);
  });
}
