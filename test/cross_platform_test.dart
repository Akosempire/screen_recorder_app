import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder_app/models/screen_region.dart';
import 'package:screen_recorder_app/platform/macos_screen_recorder.dart';
import 'package:screen_recorder_app/services/app_folders.dart';
import 'package:screen_recorder_app/services/app_update.dart';
import 'package:screen_recorder_app/services/auto_zoom.dart';
import 'package:screen_recorder_app/services/cursor_tracker.dart';
import 'package:screen_recorder_app/services/ffmpeg_process_manager.dart';
import 'package:screen_recorder_app/services/ffmpeg_binary.dart';
import 'package:screen_recorder_app/services/mac_screen_service.dart';

void main() {
  group('macOS avfoundation', () {
    const listing = '''
[AVFoundation indev @ 0x7f8] AVFoundation video devices:
[AVFoundation indev @ 0x7f8] [0] FaceTime HD Camera
[AVFoundation indev @ 0x7f8] [1] OBS Virtual Camera
[AVFoundation indev @ 0x7f8] [2] Capture screen 0
[AVFoundation indev @ 0x7f8] [3] Capture screen 1
[AVFoundation indev @ 0x7f8] AVFoundation audio devices:
[AVFoundation indev @ 0x7f8] [0] MacBook Pro Microphone
[AVFoundation indev @ 0x7f8] [1] ZoomAudioDevice
: Input/output error
''';

    test('finds screens, cameras and microphones', () {
      final devices = parseAvfoundationDevices(listing);
      expect(devices.screens.map((d) => d.index), [2, 3]);
      expect(devices.screens.first.name, 'Capture screen 0');
      expect(devices.cameras.map((d) => d.name), ['FaceTime HD Camera', 'OBS Virtual Camera']);
      expect(devices.microphones.first.index, 0);
      expect(devices.microphones.first.name, 'MacBook Pro Microphone');
    });

    test('no permission: no screens listed', () {
      final devices = parseAvfoundationDevices('''
[AVFoundation indev @ 0x1] AVFoundation video devices:
[AVFoundation indev @ 0x1] [0] FaceTime HD Camera
[AVFoundation indev @ 0x1] AVFoundation audio devices:
''');
      expect(devices.screens, isEmpty);
      expect(devices.cameras, hasLength(1));
    });

    test('capture args crop the region and pick the devices', () {
      final args = buildAvfoundationArgs(
        region: const ScreenRegion(x: 101, y: 51, width: 801, height: 601),
        outputPath: '/tmp/seg.mp4',
        encoder: 'libx264',
        screenIndex: 2,
        microphoneIndex: 0,
      );
      expect(args, containsAllInOrder(['-f', 'avfoundation']));
      expect(args, containsAllInOrder(['-capture_cursor', '1', '-capture_mouse_clicks', '1']));
      expect(args, containsAllInOrder(['-i', '2:0']));
      final vf = args[args.indexOf('-vf') + 1];
      expect(vf, startsWith('crop=800:600:'));
      expect(vf, endsWith(',fps=30'));
      expect(args, contains('aac'));
      expect(args.last, '/tmp/seg.mp4');
    });

    test('no microphone: video only, clicks can be turned off', () {
      final args = buildAvfoundationArgs(
        region: const ScreenRegion(x: 0, y: 0, width: 640, height: 480),
        outputPath: '/tmp/a.mp4',
        encoder: 'libx264',
        screenIndex: 1,
        clicks: false,
      );
      expect(args, containsAllInOrder(['-i', '1:none']));
      expect(args, containsAllInOrder(['-capture_mouse_clicks', '0']));
      expect(args, contains('-an'));
    });

    test('Retina display geometry is in pixels', () {
      final m = macMonitorFromPoints(name: 'Built-in', widthPoints: 1512, heightPoints: 982, scale: 2);
      expect(m.width, 3024);
      expect(m.height, 1964);
      expect(m.x, 0);
      expect(m.scaleFactor, 2);
    });
  });

  group('FFmpeg location', () {
    test('macOS prefers the copy inside the app, then Homebrew', () {
      const app = '/Applications/Screen Recorder.app/Contents/MacOS';
      expect(
        resolveFfmpeg(os: 'macos', appDir: app, exists: (p) => p == '$app/ffmpeg'),
        '$app/ffmpeg',
      );
      expect(
        resolveFfmpeg(os: 'macos', appDir: app, exists: (p) => p == '/opt/homebrew/bin/ffmpeg'),
        '/opt/homebrew/bin/ffmpeg',
      );
      expect(resolveFfmpeg(os: 'macos', appDir: app, exists: (_) => false), 'ffmpeg');
    });

    test('Linux falls back to PATH', () {
      expect(resolveFfmpeg(os: 'linux', appDir: '/opt/screen-recorder', exists: (_) => false), 'ffmpeg');
    });
  });

  group('folders', () {
    test('settings folder per platform', () {
      expect(
        appSettingsFolder(os: 'macos', env: {'HOME': '/Users/ada'})!.path,
        '/Users/ada/Library/Application Support/screen_recorder_app',
      );
      expect(
        appSettingsFolder(os: 'linux', env: {'HOME': '/home/ada'})!.path,
        '/home/ada/.config/screen_recorder_app',
      );
      expect(
        appSettingsFolder(os: 'linux', env: {'HOME': '/home/ada', 'XDG_CONFIG_HOME': '/cfg'})!.path,
        '/cfg/screen_recorder_app',
      );
      expect(appSettingsFolder(os: 'macos', env: const {}), isNull);
    });

    test('videos fall back to home when the folder is missing', () {
      expect(defaultVideosFolderFor(os: 'macos', env: {'HOME': '/nonexistent-home'}), '/nonexistent-home');
    });
  });

  test('update picks the right file per platform', () {
    final info = UpdateInfo.parse('''
{"build": 9, "installer": "https://x/setup.exe",
 "downloads": {"macos": "https://x/mac.dmg", "linux_deb": "https://x/a.deb", "linux_tar": "https://x/a.tar.gz", "bad": "ftp://x"}}
''')!;
    expect(info.downloadFor('windows'), 'https://x/setup.exe');
    expect(info.downloadFor('macos'), 'https://x/mac.dmg');
    expect(info.downloadFor('linux'), 'https://x/a.tar.gz');
    expect(info.downloadFor('linux', debInstall: true), 'https://x/a.deb');
    expect(info.downloads.containsKey('bad'), isFalse);
  });

  test('auto-zoom falls back to -filter_script:v on FFmpeg 6', () async {
    final dir = await Directory.systemTemp.createTemp('az_fallback_');
    addTearDown(() => dir.delete(recursive: true));
    final input = p.join(dir.path, 'in.mp4');
    File(input).writeAsStringSync('x');
    final runner = _OldFfmpeg();
    final samples = [
      for (var i = 0; i < 180; i++) CursorSample(i / 30, 100.0 + i, 100.0),
    ];
    final out = await applyAutoZoom(
      inputPath: input,
      log: CursorLog(samples, const [CursorClick(1.5, 200, 120)]),
      width: 640,
      height: 360,
      encoder: 'libx264',
      runner: runner,
    );
    expect(runner.options, [filterFromFileOption, legacyFilterFromFileOption]);
    expect(p.basename(out), 'autozoom.mp4');
    expect(isUnknownOptionError("Unrecognized option '/filter:v'."), isTrue);
    expect(isUnknownOptionError('Invalid argument'), isFalse);
  });
}

/// Behaves like FFmpeg 6: rejects `-/filter:v`, accepts `-filter_script:v`.
class _OldFfmpeg extends ProcessRunner {
  final options = <String>[];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    final option = arguments.firstWhere((a) => a.contains('filter'));
    options.add(option);
    if (option == filterFromFileOption) {
      return ProcessResult(1, 1, '', "Unrecognized option '/filter:v'.\nError splitting the argument list: Option not found");
    }
    File(arguments.last).writeAsStringSync('video');
    return ProcessResult(1, 0, '', '');
  }
}
