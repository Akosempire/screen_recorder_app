import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/recorder_exception.dart';
import '../models/screen_region.dart';
import '../services/app_logger.dart';
import '../services/ffmpeg_process_manager.dart';
import '../services/ffmpeg_recorder.dart';
import '../services/gnome_screencast_client.dart';
import '../services/linux_desktop.dart';
import '../services/screen_recorder.dart';

/// Records a rectangle through GNOME Shell's built-in screencast service.
///
/// GNOME (and other non-wlroots compositors) do not implement
/// `wlr-screencopy`, so `wf-recorder` cannot work there. Mutter exposes
/// `org.gnome.Shell.Screencast.ScreencastArea` instead.
///
/// The D-Bus connection **must stay open** for the whole segment. GNOME
/// watches the caller's unique name and tears the pipeline down when it
/// vanishes, which is what a one-shot `gdbus call` does.
///
/// Pause/resume stops and restarts the GNOME screencast (it has no pause
/// API). Stop returns the captured file as-is (WebM/MP4); paused segments
/// are concatenated with a stream copy instead of a full re-encode.
class GnomeShellScreenRecorder implements ScreenRecorder {
  GnomeShellScreenRecorder({
    ProcessRunner runner = const ProcessRunner(),
    this.encoder = 'libx264',
    GnomeScreencastSession Function()? sessionFactory,
    Future<void> Function(Duration duration)? wait,
  })  : _runner = runner,
        _sessionFactory = sessionFactory ?? DbusGnomeScreencastSession.new,
        _wait = wait ?? Future<void>.delayed;

  final ProcessRunner _runner;
  final String encoder;
  final GnomeScreencastSession Function() _sessionFactory;
  final Future<void> Function(Duration duration) _wait;

  GnomeScreencastSession? _session;
  Directory? _sessionDir;
  final List<String> _segments = [];
  ScreenRegion? _region;
  bool _recordMicrophone = false;
  bool _active = false;
  bool _paused = false;

  @override
  String get backendName => 'Wayland / GNOME Screencast';

  @override
  bool get isRecording => _active || (_paused && _segments.isNotEmpty);

  static Future<bool> isAvailable({
    ProcessRunner runner = const ProcessRunner(),
  }) async {
    try {
      final result = await runner.run('gdbus', [
        'introspect',
        '--session',
        '--dest',
        'org.gnome.Shell.Screencast',
        '--object-path',
        '/org/gnome/Shell/Screencast',
      ]);
      return result.exitCode == 0;
    } on ProcessException catch (error, stack) {
      AppLogger.debug('GNOME Screencast probe failed: $error\n$stack');
      return false;
    }
  }

  @override
  Future<void> start(
    ScreenRegion region, {
    bool recordMicrophone = false,
  }) async {
    if (!region.isValid) {
      throw RecorderException(
        userMessage:
            'The selected region is too small. Choose at least ${ScreenRegion.minWidth}×${ScreenRegion.minHeight} pixels.',
        technicalDetails: region.toString(),
      );
    }
    _region = region.evenAligned();
    _recordMicrophone = recordMicrophone;
    _paused = false;
    _segments.clear();
    _sessionDir = await Directory.systemTemp.createTemp('screen_recorder_');
    AppLogger.info('GNOME recording session dir: ${_sessionDir!.path}');
    try {
      await _startSegment();
    } catch (_) {
      await _closeSession();
      rethrow;
    }
  }

  @override
  Future<void> pause() async {
    if (_paused) {
      return;
    }
    if (!_active) {
      throw const RecorderException(userMessage: 'Nothing is recording to pause.');
    }
    await _stopScreencast();
    _paused = true;
  }

  @override
  Future<void> resume() async {
    if (!_paused) {
      return;
    }
    _paused = false;
    await _startSegment();
  }

  @override
  Future<String?> stop() async {
    if (_active) {
      await _stopScreencast();
    }
    await _closeSession();
    _paused = false;
    final dir = _sessionDir;
    final segments = List<String>.from(_segments);
    final recordMicrophone = _recordMicrophone;
    _segments.clear();
    _sessionDir = null;
    _region = null;
    _recordMicrophone = false;

    if (segments.isEmpty || dir == null) {
      return null;
    }

    if (segments.length == 1) {
      AppLogger.info('Keeping captured file without transcode: ${segments.first}');
      return segments.first;
    }

    final ext = p.extension(segments.first);
    final merged = p.join(dir.path, 'merged${ext.isEmpty ? '.webm' : ext}');
    return mergeMediaSegments(
      segments: segments,
      outputPath: merged,
      encoder: encoder,
      runner: _runner,
      sessionDir: dir.path,
      recordMicrophone: recordMicrophone,
    );
  }

  Future<void> _startSegment() async {
    final region = _region;
    final dir = _sessionDir;
    if (region == null || dir == null) {
      throw const RecorderException(userMessage: 'Recording session is not initialized.');
    }
    final stem = gnomeScreencastPathStem(
      p.join(dir.path, 'segment_${_segments.length}'),
    );
    final session = await _ensureSession();
    final output = await session.startArea(
      x: region.x,
      y: region.y,
      width: region.width,
      height: region.height,
      filePathStem: stem,
      recordMicrophone: _recordMicrophone,
    );
    final path = await _waitForCaptureFile(output, stem);
    _segments.add(path);
    _active = true;
  }

  Future<GnomeScreencastSession> _ensureSession() async {
    final existing = _session;
    if (existing != null) {
      return existing;
    }
    final session = _sessionFactory();
    await session.connect();
    _session = session;
    return session;
  }

  Future<String> _waitForCaptureFile(String returned, String stem) async {
    final candidates = <String>[
      if (returned.isNotEmpty) returned,
      stem,
      '$stem.mp4',
      '$stem.webm',
    ];
    var lastSize = 0;
    String? lastPath;
    // GNOME only returns success after the pipeline is PLAYING, but the
    // muxer may not flush the first cluster for a second or two.
    for (var i = 0; i < 40; i++) {
      final error = _session?.fatalError;
      if (error != null) {
        throw RecorderException(
          userMessage:
              'GNOME stopped the screencast unexpectedly. Nothing usable was recorded.',
          technicalDetails: error,
        );
      }
      for (final path in candidates) {
        final file = File(path);
        if (await file.exists()) {
          final size = await file.length();
          if (size > lastSize) {
            lastSize = size;
            lastPath = path;
          }
          if (size > 2048) {
            return path;
          }
        }
      }
      await _wait(const Duration(milliseconds: 200));
    }
    if (lastPath != null && lastSize > 64) {
      AppLogger.warn(
        'GNOME screencast file is small ($lastSize bytes): $lastPath',
      );
      return lastPath;
    }
    throw const RecorderException(
      userMessage:
          'GNOME started a screencast but wrote no video. If a permission prompt appeared, allow screen recording and try again.',
    );
  }

  Future<void> _stopScreencast() async {
    if (!_active) {
      return;
    }
    try {
      await _session?.stop();
    } finally {
      _active = false;
    }
    await _wait(const Duration(milliseconds: 250));
  }

  Future<void> _closeSession() async {
    final session = _session;
    _session = null;
    if (session != null) {
      await session.close();
    }
  }
}
