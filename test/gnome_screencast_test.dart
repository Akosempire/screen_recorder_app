import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/models/screen_region.dart';
import 'package:screen_recorder_app/platform/gnome_shell_screen_recorder.dart';
import 'package:screen_recorder_app/services/ffmpeg_process_manager.dart';
import 'package:screen_recorder_app/services/gnome_screencast_client.dart';
import 'package:screen_recorder_app/services/linux_desktop.dart';

void main() {
  test('parses a successful gdbus path result', () {
    const stdout = "(true, '/tmp/screen_recorder_abc/segment_0.webm')\n";
    expect(
      parseGdbusSuccessPath(stdout),
      '/tmp/screen_recorder_abc/segment_0.webm',
    );
    expect(parseGdbusBoolean(stdout), isTrue);
  });

  test('strips file:// from gdbus paths', () {
    expect(
      parseGdbusSuccessPath("(true, 'file:///tmp/shot.png')"),
      '/tmp/shot.png',
    );
  });

  test('parses a failed gdbus result', () {
    const stdout = '(false,)\n';
    expect(parseGdbusSuccessPath(stdout), isNull);
    expect(parseGdbusBoolean(stdout), isFalse);
  });

  test('GNOME path stem drops container extensions', () {
    expect(gnomeScreencastPathStem('/tmp/out.webm'), '/tmp/out');
    expect(gnomeScreencastPathStem('/tmp/out.mp4'), '/tmp/out');
    expect(gnomeScreencastPathStem('/tmp/out'), '/tmp/out');
    expect(gnomeScreencastPathStem('/tmp/out.undefined'), '/tmp/out');
  });

  test('GNOME 46 custom pipeline is written as stem.undefined', () {
    expect(
      gnomeScreencastCandidatePaths(
        returned: '/tmp/out.undefined',
        stem: '/tmp/out',
      ),
      ['/tmp/out.undefined', '/tmp/out', '/tmp/out.webm', '/tmp/out.mp4'],
    );
    expect(gnomeScreencastDisplayPath('/tmp/out.undefined'), '/tmp/out.webm');
    expect(gnomeScreencastDisplayPath('/tmp/out.webm'), '/tmp/out.webm');
  });

  test('software screencast pipeline avoids DMABuf/GL/OpenH264', () {
    expect(gnomeSoftwareWebmPipeline, contains('videoconvert'));
    expect(gnomeSoftwareWebmPipeline, contains('vp8enc'));
    expect(gnomeSoftwareWebmPipeline, contains('webmmux streamable=true'));
    expect(gnomeSoftwareWebmPipeline, isNot(contains('glupload')));
    expect(gnomeSoftwareWebmPipeline, isNot(contains('openh264')));
    expect(gnomeSoftwareWebmPipeline, isNot(contains('pipewiresrc')));
  });

  test('builds ScreencastArea arguments with a stem, not .webm', () {
    const region = ScreenRegion(x: 100, y: 80, width: 640, height: 480);
    final args = buildGnomeScreencastAreaArgs(
      x: region.x,
      y: region.y,
      width: region.width,
      height: region.height,
      outputPath: '/tmp/out.webm',
    );
    expect(args, contains('org.gnome.Shell.Screencast.ScreencastArea'));
    expect(args, contains('100'));
    expect(args, contains('80'));
    expect(args, contains('640'));
    expect(args, contains('480'));
    expect(args, contains('/tmp/out'));
    expect(args, isNot(contains('/tmp/out.webm')));
    expect(args.join(' '), contains('framerate'));
    expect(args.join(' '), contains('pipeline'));
    expect(args.join(' '), contains('vp8enc'));
    expect(args.join(' '), contains('videoconvert'));
    expect(args.join(' '), isNot(contains('glupload')));
    expect(args.join(' '), isNot(contains('openh264')));
    expect(args.join(' '), isNot(contains('pulsesrc')));
  });

  test('GNOME mic pipeline muxes pulsesrc into webmmux', () {
    expect(gnomeSoftwareWebmMicPipeline, contains('pulsesrc'));
    expect(gnomeSoftwareWebmMicPipeline, contains('opusenc'));
    expect(gnomeSoftwareWebmMicPipeline, contains('webmmux name=mux streamable=true'));
    expect(gnomeScreencastPipeline(recordMicrophone: true), contains('pulsesrc'));
    expect(
      gnomeScreencastPipeline(recordMicrophone: false),
      gnomeSoftwareWebmPipeline,
    );
  });

  test('keeps the D-Bus session open while a segment is recording', () async {
    final session = _FakeGnomeSession();
    final runner = _FakeFfmpegRunner();
    final recorder = GnomeShellScreenRecorder(
      runner: runner,
      sessionFactory: () => session,
      wait: (_) async {},
    );

    await recorder.start(
      const ScreenRegion(x: 10, y: 20, width: 320, height: 240),
    );
    expect(session.connected, isTrue);
    expect(session.closed, isFalse);
    expect(session.startCount, 1);
    expect(session.stopCount, 0);
    expect(session.lastStem, isNot(contains('.webm')));
    expect(session.lastStem, isNot(contains('.mp4')));

    final path = await recorder.stop();
    expect(session.stopCount, 1);
    expect(session.closed, isTrue);
    expect(path, isNotNull);
    expect(path, endsWith('segment_0.mp4'));
    expect(runner.ffmpegCount, 1);
    expect(runner.lastArgs, containsAllInOrder(['-i']));
    expect(runner.lastArgs, isNot(contains('concat')));
  });

  test('renames GNOME 46 .undefined captures and converts them to mp4 on stop', () async {
    final session = _FakeGnomeSession(extension: '.undefined');
    final runner = _FakeFfmpegRunner();
    final recorder = GnomeShellScreenRecorder(
      runner: runner,
      sessionFactory: () => session,
      wait: (_) async {},
    );

    await recorder.start(
      const ScreenRegion(x: 10, y: 20, width: 320, height: 240),
    );
    final path = await recorder.stop();
    expect(path, endsWith('segment_0.mp4'));
    expect(File(path!).existsSync(), isTrue);
    expect(path, isNot(contains('.undefined')));
  });

  test('concatenates paused GNOME segments with a stream copy', () async {
    final session = _FakeGnomeSession();
    final runner = _FakeFfmpegRunner();
    final recorder = GnomeShellScreenRecorder(
      runner: runner,
      sessionFactory: () => session,
      wait: (_) async {},
    );

    await recorder.start(
      const ScreenRegion(x: 10, y: 20, width: 320, height: 240),
    );
    await recorder.pause();
    await recorder.resume();
    final path = await recorder.stop();

    expect(session.startCount, 2);
    expect(path, endsWith('merged.mp4'));
    expect(runner.ffmpegCount, 2);
    expect(runner.invocations.first, containsAllInOrder(['-c', 'copy']));
    expect(runner.lastArgs, containsAllInOrder(['-c:v', 'libx264']));
    expect(runner.lastArgs, isNot(contains('+faststart')));
  });
}

class _FakeGnomeSession implements GnomeScreencastSession {
  _FakeGnomeSession({this.extension = '.webm'});

  final String extension;
  var connected = false;
  var closed = false;
  var startCount = 0;
  var stopCount = 0;
  String? lastStem;

  @override
  String? get fatalError => null;

  @override
  Future<void> connect() async {
    connected = true;
  }

  @override
  Future<String> startArea({
    required int x,
    required int y,
    required int width,
    required int height,
    required String filePathStem,
    int fps = 30,
    bool recordMicrophone = false,
  }) async {
    startCount += 1;
    lastStem = filePathStem;
    final file = File('$filePathStem$extension');
    await file.writeAsBytes(List<int>.filled(4096, 7));
    return file.path;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeFfmpegRunner extends ProcessRunner {
  int ffmpegCount = 0;
  List<String> lastArgs = const [];
  final List<List<String>> invocations = [];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    if (executable == 'ffmpeg') {
      ffmpegCount += 1;
      lastArgs = List<String>.from(arguments);
      invocations.add(lastArgs);
      await File(arguments.last).writeAsBytes(List<int>.filled(80, 1));
      return ProcessResult(1, 0, '', '');
    }
    throw ProcessException(executable, arguments, 'not faked');
  }
}
