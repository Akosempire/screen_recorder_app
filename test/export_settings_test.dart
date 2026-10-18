import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder_app/services/studio_save_service.dart';

void main() {
  ExportSettings settings() => ExportSettings(fileName: 'clip', folder: '/tmp');

  test('output size never upscales and keeps even widths', () {
    expect(exportOutputSize(1920, 1080, ExportResolution.original), (1920, 1080));
    expect(exportOutputSize(1920, 1080, ExportResolution.p720), (1280, 720));
    expect(exportOutputSize(1366, 768, ExportResolution.p720), (1280, 720));
    expect(exportOutputSize(1000, 600, ExportResolution.p720), (1000, 600));
  });

  test('default settings keep the file untouched', () {
    expect(
      buildExportArgs(
        source: 'in.mp4',
        output: 'out.mp4',
        settings: settings(),
        height: 1080,
        hasAudio: true,
      ),
      isNull,
    );
  });

  test('dropping sound copies video without re-encoding', () {
    final args = buildExportArgs(
      source: 'in.mp4',
      output: 'out.mp4',
      settings: settings()..keepSound = false,
      height: 1080,
      hasAudio: true,
    )!;
    expect(args, containsAllInOrder(['-c:v', 'copy']));
    expect(args, contains('-an'));
  });

  test('720p + high quality re-encodes with scale and crf 18', () {
    final args = buildExportArgs(
      source: 'in.mp4',
      output: 'out.mp4',
      settings: settings()
        ..resolution = ExportResolution.p720
        ..quality = ExportQuality.high,
      height: 1080,
      hasAudio: false,
    )!;
    expect(args, containsAllInOrder(['-vf', 'scale=-2:720:flags=lanczos']));
    expect(args, containsAllInOrder(['-crf', '18']));
    expect(args, contains('-an'));
    expect(args.last, 'out.mp4');
  });

  test('unique destination adds a counter instead of overwriting', () async {
    final dir = await Directory.systemTemp.createTemp('export_test_');
    addTearDown(() => dir.delete(recursive: true));
    expect(uniqueDestination(dir.path, 'clip'), p.join(dir.path, 'clip.mp4'));
    await File(p.join(dir.path, 'clip.mp4')).writeAsString('x');
    expect(uniqueDestination(dir.path, 'clip.mp4'), p.join(dir.path, 'clip (2).mp4'));
    expect(uniqueDestination(dir.path, 'a/b:c'), p.join(dir.path, 'a_b_c.mp4'));
  });
}
