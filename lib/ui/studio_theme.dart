import 'package:flutter/material.dart';

/// Visual tokens for the light "studio" layout (home screen + dialogs).
///
/// Neutral greys, near-black primary actions, white selected surfaces —
/// an editor-style look rather than a dark utility window.
class Studio {
  Studio._();

  static const Color chrome = Color(0xFFF2F2F3);
  static const Color well = Color(0xFFE4E4E7);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color track = Color(0xFFE6E6E8);
  static const Color border = Color(0xFFDCDCE0);
  static const Color divider = Color(0xFFE3E3E6);
  static const Color ink = Color(0xFF1C1C1E);
  static const Color inkSoft = Color(0xFF3A3A3C);
  static const Color muted = Color(0xFF6B6B70);
  static const Color faint = Color(0xFF9A9AA0);
  static const Color primary = Color(0xFF141414);
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color record = Color(0xFFE5483B);
  static const Color highlight = Color(0xFFFFD21F);
  static const Color ok = Color(0xFF2E9E5B);
  static const Color danger = Color(0xFFD93A2F);

  static const double radius = 10;
  static const double radiusLg = 16;

  static const List<BoxShadow> raised = [
    BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0A000000), blurRadius: 1, offset: Offset(0, 0)),
  ];

  static const List<BoxShadow> floating = [
    BoxShadow(color: Color(0x29000000), blurRadius: 32, offset: Offset(0, 12)),
    BoxShadow(color: Color(0x0F000000), blurRadius: 2, offset: Offset(0, 0)),
  ];

  static ThemeData theme(ThemeData base) {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: primary,
      onPrimary: onPrimary,
      surface: surface,
      onSurface: ink,
      outline: border,
    );
    return base.copyWith(
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: chrome,
      canvasColor: chrome,
      dividerColor: divider,
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      iconTheme: const IconThemeData(color: inkSoft, size: 20),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: primary,
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
        textStyle: TextStyle(color: onPrimary, fontSize: 12),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: primary,
        inactiveTrackColor: Color(0xFFD5D5D9),
        thumbColor: surface,
        overlayColor: Color(0x14000000),
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 10,
          elevation: 2,
          pressedElevation: 3,
        ),
        showValueIndicator: ShowValueIndicator.never,
        tickMarkShape: SliderTickMarkShape.noTickMark,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(surface),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primary
              : const Color(0xFFD5D5D9),
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    );
  }
}

class StudioText {
  StudioText._();

  static const title = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: Studio.ink,
    letterSpacing: -0.1,
  );
  static const section = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: Studio.ink,
  );
  static const body = TextStyle(fontSize: 13.5, color: Studio.ink);
  static const label = TextStyle(fontSize: 13.5, color: Studio.inkSoft);
  static const caption = TextStyle(fontSize: 12, color: Studio.muted);
  static const tiny = TextStyle(fontSize: 11.5, color: Studio.muted);
}
