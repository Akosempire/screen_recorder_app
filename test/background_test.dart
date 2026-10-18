import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/services/recording_background.dart';
import 'package:screen_recorder_app/services/studio_save_service.dart';
import 'package:screen_recorder_app/ui/background_widgets.dart';

void main() {
  group('layoutBackground', () {
    test('1080p with default padding matches the export maths', () {
      final l = layoutBackground(1920, 1080, const BackgroundSpec(kind: BackgroundKind.preset));
      expect([l.innerWidth, l.innerHeight, l.x, l.y], [1612, 906, 154, 88]);
      expect(l.radius, closeTo(18, 1e-9));
    });

    test('values are even, centred, and keep the aspect ratio', () {
      for (final (w, h) in [(1366, 768), (1284, 720), (2560, 1440), (1000, 1000), (854, 480)]) {
        for (final pad in [0.03, 0.08, 0.16]) {
          final l = layoutBackground(w, h, BackgroundSpec(kind: BackgroundKind.preset, padding: pad));
          for (final v in [l.innerWidth, l.innerHeight, l.x, l.y]) {
            expect(v.isEven, isTrue, reason: '$w×$h pad $pad: $v');
          }
          expect(l.x + l.innerWidth, lessThanOrEqualTo(w));
          expect(l.y + l.innerHeight, lessThanOrEqualTo(h));
          expect((l.x - (w - l.x - l.innerWidth)).abs(), lessThanOrEqualTo(2));
          expect(l.innerWidth / l.innerHeight, closeTo(w / h, 0.01));
        }
      }
    });

    test('padding and radius are clamped; radius scales with height', () {
      final l = layoutBackground(1280, 720, const BackgroundSpec(kind: BackgroundKind.preset, padding: 0.9, radius: 99));
      expect(l.innerWidth, 1280 - 2 * (1280 * BackgroundSpec.maxPadding).round());
      expect(l.radius, closeTo(BackgroundSpec.maxRadius * 720 / 1080, 1e-9));
    });
  });

  group('BackgroundSpec.isActive', () {
    test('none is off, presets are on, a missing image is off', () {
      expect(const BackgroundSpec().isActive, isFalse);
      expect(const BackgroundSpec(kind: BackgroundKind.preset).isActive, isTrue);
      expect(const BackgroundSpec(kind: BackgroundKind.image, imagePath: '/no/such/file.png').isActive, isFalse);
      expect(const BackgroundSpec(kind: BackgroundKind.image).isActive, isFalse);
    });
  });

  group('buildExportArgs with a background', () {
    final layout = layoutBackground(1920, 1080, const BackgroundSpec(kind: BackgroundKind.preset));

    List<String> args({bool keepSound = true, bool hasAudio = true, ExportFrameRate fps = ExportFrameRate.original}) =>
        buildExportArgs(
          source: 'in.mp4',
          output: 'out.mp4',
          settings: ExportSettings(fileName: 'x', folder: '.', keepSound: keepSound, frameRate: fps),
          height: 1080,
          hasAudio: hasAudio,
          background: layout,
          backgroundFrame: 'frame.png',
        )!;

    test('scales the recording into the window and overlays the frame', () {
      final a = args();
      expect(a.sublist(0, 9), ['-y', '-hide_banner', '-i', 'in.mp4', '-loop', '1', '-i', 'frame.png', '-filter_complex']);
      expect(
        a[9],
        '[0:v]scale=1612:906:flags=lanczos,setsar=1,pad=1920:1080:154:88:color=black[rec];'
        '[rec][1:v]overlay=0:0:shortest=1,format=yuv420p[out]',
      );
      expect(a, containsAllInOrder(['-map', '[out]', '-map', '0:a?', '-c:a', 'copy', '-c:v', 'libx264']));
      expect(a.last, 'out.mp4');
    });

    test('always re-encodes, drops sound on request, and applies 15 fps', () {
      expect(args(keepSound: false), contains('-an'));
      expect(args(hasAudio: false), contains('-an'));
      expect(args(fps: ExportFrameRate.fps15)[9], contains('overlay=0:0:shortest=1,fps=15,format=yuv420p'));
    });

    test('without a background the old behaviour is unchanged', () {
      expect(
        buildExportArgs(
          source: 'in.mp4',
          output: 'out.mp4',
          settings: ExportSettings(fileName: 'x', folder: '.'),
          height: 1080,
          hasAudio: true,
        ),
        isNull,
      );
    });
  });

  test('parseVideoSize reads the stream line of ffmpeg -i', () {
    const info = '''
  Duration: 00:00:03.00, start: 0.000000, bitrate: 2970 kb/s
  Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 1366x766 [SAR 1:1 DAR 683:383], 2966 kb/s, 30 fps
  Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, mono, fltp, 69 kb/s''';
    expect(parseVideoSize(info), (1366, 766));
    expect(parseVideoSize('no video here'), isNull);
  });

  testWidgets('renderBackgroundFrame: opaque background, transparent window', (tester) async {
    await tester.runAsync(() async {
      for (final preset in BackgroundPreset.values) {
        final spec = BackgroundSpec(kind: BackgroundKind.preset, preset: preset);
        final layout = layoutBackground(320, 180, spec);
        final png = await renderBackgroundFrame(layout, spec);
        expect(png.sublist(1, 4), 'PNG'.codeUnits, reason: preset.name);
        final rgba = await _decode(png);
        int alpha(int x, int y) => rgba[(y * 320 + x) * 4 + 3];
        expect(alpha(2, 2), 255, reason: '${preset.name} corner');
        expect(alpha(160, 90), 0, reason: '${preset.name} centre');
        // The window's corner is rounded: its very corner pixel keeps some background.
        expect(alpha(layout.x, layout.y), greaterThan(0), reason: '${preset.name} rounded corner');
      }
    });
  });

  testWidgets('renderBackgroundFrame covers the frame with an uploaded image', (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('bg_test');
      try {
        // A 4×2 solid red picture, stretched to cover a 16:9 frame.
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 4, 2), Paint()..color = const Color(0xFFFF0000));
        final img = await recorder.endRecording().toImage(4, 2);
        final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        final file = File('${dir.path}/red.png')..writeAsBytesSync(bytes);

        final spec = BackgroundSpec(kind: BackgroundKind.image, imagePath: file.path, shadow: false);
        expect(spec.isActive, isTrue);
        final rgba = await _decode(await renderBackgroundFrame(layoutBackground(160, 90, spec), spec));
        expect(rgba.sublist(0, 4), [255, 0, 0, 255]);

        final copied = await importBackgroundImage(file.path, Directory('${dir.path}/backgrounds'));
        expect(File(copied).readAsBytesSync(), bytes);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  testWidgets('RecordingOnBackground frames the child, or shows it plainly when off', (tester) async {
    const child = ColoredBox(key: ValueKey('frame'), color: Color(0xFF00FF00));
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 400,
          height: 225,
          child: RecordingOnBackground(spec: BackgroundSpec(kind: BackgroundKind.preset), child: child),
        ),
      ),
    ));
    final framed = tester.getSize(find.byKey(const ValueKey('frame')));
    final l = layoutBackground(400, 225, const BackgroundSpec(kind: BackgroundKind.preset));
    expect(framed, Size(l.innerWidth.toDouble(), l.innerHeight.toDouble()));

    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(width: 400, height: 225, child: RecordingOnBackground(spec: BackgroundSpec(), child: child)),
      ),
    ));
    expect(tester.getSize(find.byKey(const ValueKey('frame'))), const Size(400, 225));
  });
}

Future<Uint8List> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  return data!.buffer.asUint8List();
}
