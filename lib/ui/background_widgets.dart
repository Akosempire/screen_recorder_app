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

/// The background alone (preset, colour or uploaded image), filling its box.
class BackgroundFill extends StatelessWidget {
  const BackgroundFill({super.key, required this.spec});

  final BackgroundSpec spec;

  @override
  Widget build(BuildContext context) {
    final path = spec.imagePath;
    if (spec.kind == BackgroundKind.image && path != null && File(path).existsSync()) {
      return Image.file(File(path), fit: BoxFit.cover, gaplessPlayback: true);
    }
    if (spec.kind == BackgroundKind.color) return ColoredBox(color: Color(spec.color | 0xFF000000));
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

/// Asks for a solid colour: ready-made swatches, hue / shade sliders and a
/// hex code. Returns the chosen ARGB colour, or null when cancelled.
Future<int?> showBackgroundColorPicker(BuildContext context, int initial) {
  return showDialog<int>(
    context: context,
    builder: (_) => _ColorPickerDialog(initial: initial | 0xFF000000),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial});

  final int initial;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv = HSVColor.fromColor(Color(widget.initial));
  // The exact colour chosen: swatches and hex codes are kept as typed; the
  // sliders work in HSV.
  late int _argb = widget.initial | 0xFF000000;
  late final TextEditingController _hex = TextEditingController(text: colorHex(widget.initial));

  void _set(HSVColor hsv, {bool updateHex = true}) {
    setState(() {
      _hsv = hsv;
      _argb = hsv.toColor().toARGB32() | 0xFF000000;
    });
    if (updateHex) _hex.text = colorHex(_argb);
  }

  void _setExact(int argb, {bool updateHex = true}) {
    setState(() {
      _argb = argb | 0xFF000000;
      _hsv = HSVColor.fromColor(Color(_argb));
    });
    if (updateHex) _hex.text = colorHex(_argb);
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Widget _slider(String label, double value, double max, ValueChanged<double> onChanged, List<Color> track) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          SizedBox(
            height: 28,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // The colour bar, with the slider's thumb riding on top of it.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Container(
                    height: 10,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(5),
                      gradient: LinearGradient(colors: track),
                    ),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 0,
                    overlayShape: SliderComponentShape.noOverlay,
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(value: value.clamp(0, max).toDouble(), max: max, onChanged: onChanged),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(_argb);
    return AlertDialog(
      title: const Text('Background colour'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 64,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x22000000)),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in backgroundSwatches)
                    Tooltip(
                      message: colorHex(c),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _setExact(c),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: (c | 0xFF000000) == _argb ? const Color(0xFF0080FF) : const Color(0x33000000),
                              width: (c | 0xFF000000) == _argb ? 2.5 : 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              _slider('Colour', _hsv.hue, 360, (v) => _set(_hsv.withHue(v)), [
                for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
              ]),
              _slider('Strength', _hsv.saturation, 1, (v) => _set(_hsv.withSaturation(v)), [
                _hsv.withSaturation(0).toColor(),
                _hsv.withSaturation(1).toColor(),
              ]),
              _slider('Brightness', _hsv.value, 1, (v) => _set(_hsv.withValue(v)), [
                Colors.black,
                _hsv.withValue(1).toColor(),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: _hex,
                decoration: const InputDecoration(labelText: 'Hex code', hintText: '#1D4ED8', isDense: true),
                onChanged: (t) {
                  final parsed = parseColorHex(t);
                  if (parsed != null) _setExact(parsed, updateHex: false);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _argb), child: const Text('Use this colour')),
      ],
    );
  }
}
