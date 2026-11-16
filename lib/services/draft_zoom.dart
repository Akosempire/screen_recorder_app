import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'auto_zoom.dart';
import 'cursor_tracker.dart';
import 'draft_store.dart';
import 'ffmpeg_process_manager.dart';

/// Recordings longer than this are saved right away without auto-zoom (it
/// re-encodes the whole video, which takes hours for a long class). The
/// editor can still apply it later.
const Duration autoZoomRightAwayLimit = Duration(minutes: 10);

/// Everything auto-zoom needs, kept with a draft as `zoom.json` so it can be
/// applied later, even after the app restarts.
class PendingZoom {
  const PendingZoom({
    required this.log,
    required this.width,
    required this.height,
    required this.encoder,
    required this.hasAudio,
    required this.duration,
    this.settings = const AutoZoomSettings(),
    this.enabled = true,
  });

  /// The user had auto-zoom switched on when they recorded.
  final bool enabled;

  final CursorLog log;
  final int width;
  final int height;
  final String encoder;
  final bool hasAudio;
  final Duration duration;
  final AutoZoomSettings settings;

  /// Whether to zoom straight after Stop: only if it was switched on, and
  /// only for short recordings.
  bool get rightAway => enabled && duration <= autoZoomRightAwayLimit;

  Map<String, Object?> toJson() => {
        'version': 1,
        'width': width,
        'height': height,
        'encoder': encoder,
        'hasAudio': hasAudio,
        'durationMs': duration.inMilliseconds,
        'settings': {
          'maxZoom': settings.maxZoom,
          'hold': settings.hold,
          'panTau': settings.panTau,
          'zoomTau': settings.zoomTau,
        },
        'samples': [
          for (final s in log.samples) [_r(s.t), _r(s.x), _r(s.y)],
        ],
        'clicks': [
          for (final c in log.clicks) [_r(c.t), _r(c.x), _r(c.y), if (c.right) 1],
        ],
      };

  static double _r(double v) => (v * 1000).round() / 1000;

  static PendingZoom? fromJson(Object? json) {
    if (json is! Map) return null;
    double d(Object? v, double fallback) => v is num ? v.toDouble() : fallback;
    final s = json['settings'] is Map ? json['settings'] as Map : const {};
    final samples = <CursorSample>[];
    for (final row in (json['samples'] as List? ?? const [])) {
      if (row is List && row.length >= 3) samples.add(CursorSample(d(row[0], 0), d(row[1], 0), d(row[2], 0)));
    }
    final clicks = <CursorClick>[];
    for (final row in (json['clicks'] as List? ?? const [])) {
      if (row is List && row.length >= 3) {
        clicks.add(CursorClick(d(row[0], 0), d(row[1], 0), d(row[2], 0), right: row.length > 3 && row[3] == 1));
      }
    }
    final width = json['width'];
    final height = json['height'];
    if (width is! int || height is! int) return null;
    const defaults = AutoZoomSettings();
    return PendingZoom(
      log: CursorLog(samples, clicks),
      width: width,
      height: height,
      encoder: json['encoder'] is String ? json['encoder'] as String : 'libx264',
      hasAudio: json['hasAudio'] == true,
      duration: Duration(milliseconds: json['durationMs'] is int ? json['durationMs'] as int : 0),
      settings: AutoZoomSettings(
        maxZoom: d(s['maxZoom'], defaults.maxZoom),
        hold: d(s['hold'], defaults.hold),
        panTau: d(s['panTau'], defaults.panTau),
        zoomTau: d(s['zoomTau'], defaults.zoomTau),
      ),
    );
  }
}

String zoomPlanPath(Draft d) => p.join(d.folder, 'zoom.json');

/// Auto-zoom can still be applied: there's a plan and it hasn't been done.
bool canApplyAutoZoom(Draft d) => File(zoomPlanPath(d)).existsSync() && !d.hasOriginal;

Future<void> writeZoomPlan(Draft d, PendingZoom zoom) async {
  final file = File(zoomPlanPath(d));
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(jsonEncode(zoom.toJson()));
  await tmp.rename(file.path);
}

Future<PendingZoom?> readZoomPlan(Draft d) async {
  try {
    final file = File(zoomPlanPath(d));
    if (!await file.exists()) return null;
    return PendingZoom.fromJson(jsonDecode(await file.readAsString()));
  } catch (error) {
    AppLogger.warn('Could not read the zoom plan for ${d.folder}: $error');
    return null;
  }
}

/// Applies auto-zoom to a draft: the zoomed video becomes `video.mp4` and the
/// recording as captured is kept as `original.mp4`. The draft stays playable
/// and exportable the whole time; if the app closes midway nothing is lost.
/// Returns true when the video was zoomed.
Future<bool> applyAutoZoomToDraft(
  Draft d, {
  DraftStore? store,
  ProcessRunner runner = const ProcessRunner(),
  void Function(double fraction)? onProgress,
}) async {
  final plan = await readZoomPlan(d);
  if (plan == null || d.hasOriginal) return false;
  final out = await applyAutoZoom(
    inputPath: d.videoPath,
    log: plan.log,
    width: plan.width,
    height: plan.height,
    encoder: plan.encoder,
    hasAudio: plan.hasAudio,
    settings: plan.settings,
    runner: runner,
    duration: plan.duration,
    onProgress: onProgress,
  );
  if (out == d.videoPath || !await File(out).exists()) return false;
  await File(d.videoPath).rename(d.originalPath);
  try {
    await File(out).rename(d.videoPath);
  } catch (error) {
    // Put the recording back if the zoomed file can't take its place.
    await File(d.originalPath).rename(d.videoPath);
    rethrow;
  }
  await (store ?? DraftStore.instance).zoomApplied(d.id);
  AppLogger.info('Auto-zoom applied to ${d.folder}');
  return true;
}
