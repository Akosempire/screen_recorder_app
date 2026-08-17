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
        const SingleActivator(LogicalKeyboardKey.escape):
            const CancelSelectionIntent(),
        const SingleActivator(LogicalKeyboardKey.enter):
            const ConfirmRegionIntent(),
      };
}
