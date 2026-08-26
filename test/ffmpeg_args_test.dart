import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/models/screen_region.dart';
import 'package:screen_recorder_app/services/ffmpeg_recorder.dart';
import 'package:screen_recorder_app/services/linux_screen_service.dart';

void main() {
  test('X11 grab arguments capture the selected region without audio', () {
    const region = ScreenRegion(x: 120, y: 40, width: 1280, height: 720);
    final args = buildX11GrabArgs(
      region: region,
      display: ':0.0',
      outputPath: '/tmp/out.mp4',
      encoder: 'libx264',
    );

    expect(args, containsAllInOrder(['-f', 'x11grab']));
    expect(args, containsAllInOrder(['-video_size', '1280x720']));
    expect(args, containsAllInOrder(['-i', ':0.0+120,40']));
    expect(args, contains('-an'));
    expect(args, containsAllInOrder(['-c:v', 'libx264']));
    expect(args, containsAllInOrder(['-preset', 'ultrafast']));
    expect(args, containsAllInOrder(['-threads', '0']));
    expect(args.contains('+faststart'), isFalse);
    expect(args.contains('pulse'), isFalse);
    expect(args.contains('alsa'), isFalse);
    expect(args.last, '/tmp/out.mp4');
  });

  test('X11 grab arguments mix in PulseAudio default when microphone is on', () {
    const region = ScreenRegion(x: 120, y: 40, width: 1280, height: 720);
    final args = buildX11GrabArgs(
      region: region,
      display: ':0.0',
      outputPath: '/tmp/out.mp4',
      encoder: 'libx264',
      recordMicrophone: true,
    );

    expect(args, containsAllInOrder(['-f', 'x11grab']));
    expect(args, containsAllInOrder(['-f', 'pulse', '-thread_queue_size', '512', '-i', 'default']));
    expect(args, containsAllInOrder(['-c:a', 'aac']));
    expect(args.contains('-an'), isFalse);
    expect(args.last, '/tmp/out.mp4');
  });

  test('even dimensions are forced for odd regions', () {
    const region = ScreenRegion(x: 1, y: 1, width: 321, height: 199);
    final args = buildX11GrabArgs(
      region: region,
      display: ':1',
      outputPath: '/tmp/odd.mp4',
      encoder: 'libx264',
    );
    expect(args, contains('320x198'));
    expect(args, contains(':1+1,1'));
  });

  test('wf-recorder geometry uses desktop coordinates', () {
    const region = ScreenRegion(x: -100, y: 50, width: 640, height: 480);
    final args = buildWfRecorderArgs(
      region: region,
      outputPath: '/tmp/way.mp4',
    );
    expect(args, containsAllInOrder(['-g', '-100,50 640x480']));
    expect(args, containsAllInOrder(['-f', '/tmp/way.mp4']));
    expect(args.contains('-a'), isFalse);
  });

  test('wf-recorder adds -a when microphone is on', () {
    const region = ScreenRegion(x: 0, y: 0, width: 640, height: 480);
    final args = buildWfRecorderArgs(
      region: region,
      outputPath: '/tmp/way.mp4',
      recordMicrophone: true,
    );
    expect(args, contains('-a'));
    expect(args, containsAllInOrder(['-f', '/tmp/way.mp4']));
  });

  test('live encode args skip the slow faststart remux pass', () {
    final args = ffmpegEncodeArgs(
      encoder: 'libx264',
      outputPath: '/tmp/out.mp4',
    );
    expect(args, containsAllInOrder(['-preset', 'ultrafast']));
    expect(args, isNot(contains('-movflags')));
    expect(args, isNot(contains('+faststart')));
  });

  test('concat copy does not rewrite the file with faststart', () {
    final args = ffmpegConcatCopyArgs(
      listPath: '/tmp/concat.txt',
      outputPath: '/tmp/merged.webm',
    );
    expect(args, containsAllInOrder(['-f', 'concat']));
    expect(args, containsAllInOrder(['-c', 'copy']));
    expect(args, isNot(contains('-movflags')));
    expect(args, isNot(contains('+faststart')));
    expect(args, contains('-an'));
  });

  test('concat copy keeps audio when microphone was recorded', () {
    final args = ffmpegConcatCopyArgs(
      listPath: '/tmp/concat.txt',
      outputPath: '/tmp/merged.mp4',
      recordMicrophone: true,
    );
    expect(args, containsAllInOrder(['-c', 'copy']));
    expect(args.contains('-an'), isFalse);
  });

  test('parseXrandr reads connected monitors including negative offsets', () {
    const output = '''
Screen 0: minimum 320 x 200, current 3840 x 1080, maximum 16384 x 16384
eDP-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 344mm x 194mm
HDMI-1 connected 1920x1080+-1920+0 (normal left inverted right x axis y axis) 510mm x 290mm
DP-1 disconnected (normal left inverted right x axis y axis)
''';
    final monitors = parseXrandr(output);
    expect(monitors, hasLength(2));
    expect(monitors[0].name, 'eDP-1');
    expect(monitors[0].primary, isTrue);
    expect(monitors[0].x, 0);
    expect(monitors[1].name, 'HDMI-1');
    expect(monitors[1].x, -1920);
    expect(monitors[1].width, 1920);
  });
}
