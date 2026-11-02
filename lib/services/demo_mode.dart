import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../screens/editor_screen.dart';
import '../screens/export_dialog.dart';
import 'draft_store.dart';
import 'recording_background.dart';
import 'recording_edit.dart';
import 'recording_library.dart';
import 'recording_options.dart';
import 'studio_save_service.dart';

/// Launch-time demo states used to take real screenshots of the app (for the
/// website and release notes). Not reachable from the UI.
///
///   screen_recorder_app.exe --demo=compare --demo-assets=C:\path\to\demo
///
/// With assets, the Recordings list shows a few sample recordings.
///
/// States: home, tour, compare, export, camera, background, edit.
/// The assets folder holds before.png, after.png and strip.png.
class DemoMode {
  DemoMode._();

  static String? state;
  static String? assets;

  static bool get active => state != null;

  static void parse(List<String> args) {
    for (final arg in args) {
      if (arg.startsWith('--demo=')) state = arg.substring(7);
      if (arg.startsWith('--demo-assets=')) assets = arg.substring(14);
    }
  }

  static bool get wantsRecording =>
      state == 'compare' || state == 'export' || state == 'camera' || state == 'background' || state == 'edit';

  /// Prepares options and the sample recording. Call before the UI builds.
  static void prepare() {
    if (!active) return;
    final options = RecordingOptions.instance;
    options.tourDone = state != 'tour';
    if (state == 'background' || state == 'edit') {
      options.setBackgroundPreset(BackgroundPreset.ocean);
    }
    final dir = assets;
    if (dir == null) return;
    File file(String name) => File('$dir${Platform.pathSeparator}$name');
    final before = file('before.png');
    final after = file('after.png');
    if (!before.existsSync() || !after.existsSync()) return;
    final newest = _seedRecordings(after);
    if (!wantsRecording) return;
    final recording = LastRecording(
      finalPath: after.path,
      originalPath: before.path,
      width: 1920,
      height: 1080,
      duration: const Duration(seconds: 42),
      hasAudio: true,
      focusSeconds: 2,
      draftId: newest,
    )
      ..beforeImage = before
      ..afterImage = after
      ..filmstrip = file('strip.png').existsSync() ? file('strip.png') : null
      ..savedPath = 'Product walkthrough.mp4';
    RecordingLibrary.instance.register(recording);
  }

  /// A few sample recordings for the Recordings list (in a temp folder, so
  /// the real ones are never touched). Returns the newest one's id.
  static String? _seedRecordings(File picture) {
    try {
      final root = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}screen_recorder_demo_recordings');
      if (root.existsSync()) root.deleteSync(recursive: true);
      final now = DateTime.now();
      final samples = [
        (now.subtract(const Duration(minutes: 3)), 42, false),
        (now.subtract(const Duration(hours: 2)), 95, false),
        (now.subtract(const Duration(days: 1, hours: 1)), 18, true),
        (now.subtract(const Duration(days: 6)), 204, true),
      ];
      String? newest;
      for (final (created, seconds, exported) in samples) {
        final id = '${created.millisecondsSinceEpoch}';
        newest ??= id;
        final folder = Directory('${root.path}${Platform.pathSeparator}$id')..createSync(recursive: true);
        final draft = Draft(
          id: id,
          folder: folder.path,
          createdAt: created,
          width: 1920,
          height: 1080,
          duration: Duration(seconds: seconds),
          hasAudio: true,
          exportedTo: exported ? ['Product walkthrough.mp4'] : [],
        );
        File(draft.videoPath).writeAsStringSync('demo');
        picture.copySync(draft.thumbPath);
        File('${folder.path}${Platform.pathSeparator}draft.json').writeAsStringSync(jsonEncode(draft.toJson()));
      }
      DraftStore.instance.useRoot(root);
      return newest;
    } catch (_) {
      return null;
    }
  }

  /// Opens dialogs for states that need them, once the app is on screen.
  static Future<void> afterFirstFrame(GlobalKey<NavigatorState> navigator) async {
    if (state == 'edit') {
      final recording = RecordingLibrary.instance.last;
      final nav = navigator.currentState;
      if (recording == null || nav == null) return;
      final edit = RecordingEdit(recording.duration.inMilliseconds / 1000.0)
        ..trimStart = 2.5
        ..trimEnd = 38
        ..playhead = 12;
      edit.playhead = 21;
      final i = edit.addCutAtPlayhead();
      edit.setCut(i, 18, 24.5);
      edit.playhead = 12;
      await nav.push<String>(
        MaterialPageRoute(
          builder: (_) => EditorScreen(
            recording: recording,
            initialEdit: edit,
            playback: false, // still screenshot; no media engine needed
            onExport: (_) async => null,
            onSaveDraft: (_) async {},
          ),
        ),
      );
      return;
    }
    if (state != 'export') return;
    final recording = RecordingLibrary.instance.last;
    final context = navigator.currentContext;
    if (recording == null || context == null) return;
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x33000000),
      builder: (_) => ExportDialog(
        recording: recording,
        settings: ExportSettings(
          fileName: 'Product walkthrough',
          folder: r'C:\Users\you\Videos',
          keepSound: true,
        ),
        onExport: (_) async => '',
      ),
    );
  }
}
