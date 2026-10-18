import 'package:flutter/material.dart';

import 'studio_theme.dart';

/// Pill-shaped segmented control (track with a raised white selection).
class StudioSegmented<T> extends StatelessWidget {
  const StudioSegmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.dense = false,
  });

  final List<StudioSegment<T>> segments;
  final T value;
  final ValueChanged<T>? onChanged;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Studio.track,
        borderRadius: BorderRadius.circular(Studio.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final segment in segments)
            _SegmentButton(
              label: segment.label,
              detail: segment.detail,
              selected: segment.value == value,
              enabled: onChanged != null && segment.enabled,
              dense: dense,
              onTap: () => onChanged?.call(segment.value),
            ),
        ],
      ),
    );
  }
}

class StudioSegment<T> {
  const StudioSegment(this.value, this.label, {this.detail, this.enabled = true});

  final T value;
  final String label;
  final String? detail;
  final bool enabled;
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.dense,
    this.detail,
  });

  final String label;
  final String? detail;
  final bool selected;
  final bool enabled;
  final bool dense;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Studio.ink : Studio.faint;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 14 : 18,
            vertical: dense ? 6 : 7,
          ),
          decoration: BoxDecoration(
            color: selected ? Studio.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(Studio.radius - 3),
            boxShadow: selected ? Studio.raised : null,
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: label,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                if (detail != null)
                  TextSpan(
                    text: ' $detail',
                    style: const TextStyle(color: Studio.muted),
                  ),
              ],
            ),
            style: TextStyle(fontSize: dense ? 13 : 13.5, color: color),
          ),
        ),
      ),
    );
  }
}

/// Near-black primary button.
class StudioPrimaryButton extends StatelessWidget {
  const StudioPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.leading,
    this.busy = false,
    this.large = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget? leading;
  final bool busy;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: Studio.primary,
        foregroundColor: Studio.onPrimary,
        disabledBackgroundColor: const Color(0xFF5A5A5E),
        disabledForegroundColor: const Color(0xFFE0E0E0),
        padding: EdgeInsets.symmetric(
          horizontal: large ? 22 : 16,
          vertical: large ? 16 : 12,
        ),
        minimumSize: Size(0, large ? 46 : 38),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Studio.radius - 2),
        ),
        textStyle: TextStyle(
          fontSize: large ? 14.5 : 13.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Studio.onPrimary,
              ),
            ),
            const SizedBox(width: 10),
          ] else if (leading != null) ...[
            leading!,
            const SizedBox(width: 8),
          ],
          Text(label),
        ],
      ),
    );
  }
}

/// Light secondary button.
class StudioSecondaryButton extends StatelessWidget {
  const StudioSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: Studio.track,
        foregroundColor: Studio.ink,
        disabledForegroundColor: Studio.faint,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        minimumSize: const Size(0, 38),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Studio.radius - 2),
        ),
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16),
            const SizedBox(width: 6),
          ],
          Text(label),
        ],
      ),
    );
  }
}

/// Small grey pill with optional icon, used as a dropdown-like trigger.
class StudioPill extends StatelessWidget {
  const StudioPill({
    super.key,
    required this.label,
    this.icon,
    this.trailing,
    this.onTap,
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final IconData? trailing;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final pill = Material(
      color: Studio.track,
      borderRadius: BorderRadius.circular(Studio.radius - 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Studio.radius - 2),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: Studio.inkSoft),
                const SizedBox(width: 6),
              ],
              Text(label, style: StudioText.label),
              if (trailing != null) ...[
                const SizedBox(width: 6),
                Icon(trailing, size: 14, color: Studio.muted),
              ],
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip!, child: pill);
  }
}

/// Keyboard key chip, e.g. `Space`.
class StudioKbd extends StatelessWidget {
  const StudioKbd(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Studio.track,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Studio.border),
      ),
      child: Text(text, style: StudioText.tiny.copyWith(color: Studio.inkSoft)),
    );
  }
}

/// Picture tile with a caption; the selected tile gets a dark ring.
class StudioTile extends StatelessWidget {
  const StudioTile({
    super.key,
    required this.label,
    required this.preview,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Widget preview;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Studio.radius + 2),
                border: Border.all(
                  color: selected ? Studio.primary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Studio.radius - 2),
                child: AspectRatio(aspectRatio: 1.6, child: preview),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? Studio.ink : Studio.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Label · slider · value, as in an "Adjust" panel.
class StudioSliderRow extends StatelessWidget {
  const StudioSliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String display;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Text(label, style: StudioText.body),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: StudioText.caption,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small rounded label chip shown on top of previews ("Before", "After").
class StudioBadge extends StatelessWidget {
  const StudioBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xE6FFFFFF),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: Studio.inkSoft,
        ),
      ),
    );
  }
}
