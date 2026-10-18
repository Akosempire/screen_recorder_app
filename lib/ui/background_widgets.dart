import 'dart:io';

import 'package:flutter/material.dart';

import '../services/recording_background.dart';

/// Paints one built-in background (used for tiles and the stage preview).
class BackgroundPresetPainter extends CustomPainter {
  const BackgroundPresetPainter(this.preset);

  final BackgroundPreset preset;

  @override
  void paint(Canvas canvas, Size size) => paintBackgroundPreset(canvas, size, preset);

  @override
  bool shouldRepaint(BackgroundPresetPainter old) => old.preset != preset;
}

/// The background alone (preset or uploaded image), filling its box.
class BackgroundFill extends StatelessWidget {
  const BackgroundFill({super.key, required this.spec});

  final BackgroundSpec spec;

  @override
  Widget build(BuildContext context) {
    final path = spec.imagePath;
    if (spec.kind == BackgroundKind.image && path != null && File(path).existsSync()) {
      return Image.file(File(path), fit: BoxFit.cover, gaplessPlayback: true);
    }
    return CustomPaint(painter: BackgroundPresetPainter(spec.preset));
  }
}

class _ShadowPainter extends CustomPainter {
  const _ShadowPainter(this.rrect);

  final RRect rrect;

  @override
  void paint(Canvas canvas, Size size) => paintRecordingShadow(canvas, rrect, size.height);

  @override
  bool shouldRepaint(_ShadowPainter old) => old.rrect != rrect;
}

/// Shows [child] (a frame of the recording) framed on [spec], exactly as the
/// export lays it out. Without an active background it shows [child] as is.
class RecordingOnBackground extends StatelessWidget {
  const RecordingOnBackground({super.key, required this.spec, required this.child});

  final BackgroundSpec spec;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!spec.isActive) return child;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth.round();
        final h = box.maxHeight.round();
        if (w < 4 || h < 4) return child;
        final layout = layoutBackground(w, h, spec);
        return Stack(
          fit: StackFit.expand,
          children: [
            BackgroundFill(spec: spec),
            if (spec.shadow) CustomPaint(painter: _ShadowPainter(layout.innerRRect)),
            Positioned.fromRect(
              rect: layout.inner,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(layout.radius),
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Copies an uploaded picture into the app's settings folder, so the
/// background keeps working if the original file is moved or deleted.
Future<String> importBackgroundImage(String path, Directory folder) async {
  await folder.create(recursive: true);
  final name = path.split(RegExp(r'[\\/]')).last;
  final target = File('${folder.path}${Platform.pathSeparator}'
      '${DateTime.now().millisecondsSinceEpoch}_$name');
  await File(path).copy(target.path);
  return target.path;
}
