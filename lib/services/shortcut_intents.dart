import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class StartRecordingIntent extends Intent {
  const StartRecordingIntent();
}

class TogglePauseIntent extends Intent {
  const TogglePauseIntent();
}

class StopRecordingIntent extends Intent {
  const StopRecordingIntent();
}

class CancelSelectionIntent extends Intent {
  const CancelSelectionIntent();
}

class ConfirmRegionIntent extends Intent {
  const ConfirmRegionIntent();
}

/// Default bindings. Replace this map to change shortcuts later.
class AppShortcutMap {
  static Map<ShortcutActivator, Intent> get defaults => {
        const SingleActivator(
          LogicalKeyboardKey.keyR,
          control: true,
          shift: true,
        ): const StartRecordingIntent(),
        const SingleActivator(
          LogicalKeyboardKey.space,
          control: true,
          shift: true,
        ): const TogglePauseIntent(),
        const SingleActivator(
          LogicalKeyboardKey.keyS,
          control: true,
          shift: true,
        ): const StopRecordingIntent(),
        // macOS: the same shortcuts with Command instead of Control.
        if (Platform.isMacOS) ...{
          const SingleActivator(LogicalKeyboardKey.keyR, meta: true, shift: true):
              const StartRecordingIntent(),
          const SingleActivator(LogicalKeyboardKey.space, meta: true, shift: true):
              const TogglePauseIntent(),
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true):
              const StopRecordingIntent(),
        },
        const SingleActivator(LogicalKeyboardKey.escape):
            const CancelSelectionIntent(),
        const SingleActivator(LogicalKeyboardKey.enter):
            const ConfirmRegionIntent(),
      };
}

/// How a Ctrl/Cmd + Shift + [key] shortcut is written on this platform.
String shortcutLabel(String key) =>
    Platform.isMacOS ? '⌘⇧$key' : 'Ctrl+Shift+$key';
