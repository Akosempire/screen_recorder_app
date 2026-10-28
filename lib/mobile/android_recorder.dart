import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A saved recording in Movies/Screen Recorder.
@immutable
class PhoneRecording {
  const PhoneRecording({
    required this.uri,
    required this.name,
    required this.duration,
    required this.size,
    required this.added,
  });

  final String uri;
  final String name;
  final Duration duration;
  final int size;
  final DateTime added;

  static PhoneRecording? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final uri = raw['uri'];
    if (uri is! String) return null;
    int n(Object? v) => v is int ? v : 0;
    return PhoneRecording(
      uri: uri,
      name: raw['name'] is String ? raw['name'] as String : 'Recording',
      duration: Duration(milliseconds: n(raw['durationMs'])),
      size: n(raw['size']),
      added: DateTime.fromMillisecondsSinceEpoch(n(raw['added'])),
    );
  }
}

enum PhoneRecorderState { idle, starting, recording, paused }

/// Talks to MainActivity / RecorderService (android/app/src/main/kotlin).
class AndroidRecorder extends ChangeNotifier {
  AndroidRecorder({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('screen_recorder_app/android') {
    _channel.setMethodCallHandler(_onEvent);
  }

  final MethodChannel _channel;

  PhoneRecorderState _state = PhoneRecorderState.idle;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  List<PhoneRecording> _recordings = const [];
  String? _message;
  bool _lastStoppedAtLimit = false;
  final _thumbs = <String, Future<Uint8List?>>{};

  PhoneRecorderState get state => _state;
  Duration get elapsed => _elapsed;
  List<PhoneRecording> get recordings => _recordings;
  bool get busy => _state != PhoneRecorderState.idle;

  /// A one-off message for the user (errors, "microphone not allowed").
  String? takeMessage() {
    final m = _message;
    _message = null;
    return m;
  }

  bool get lastStoppedAtLimit => _lastStoppedAtLimit;

  @override
  void dispose() {
    _ticker?.cancel();
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  /// Asks Android for permission and starts recording. [maxSeconds] is the
  /// free limit (null for Pro): Android stops the recording itself there.
  Future<void> start({required bool mic, int? maxSeconds}) async {
    if (busy) return;
    _set(PhoneRecorderState.starting);
    _lastStoppedAtLimit = false;
    try {
      await _channel.invokeMethod<Object?>('start', {'mic': mic, 'maxSeconds': maxSeconds ?? 0});
      // The service reports "started" (or "error") shortly after.
    } on PlatformException catch (e) {
      _message = e.code == 'denied' ? null : (e.message ?? 'Could not start recording.');
      _set(PhoneRecorderState.idle);
    }
  }

  Future<void> stop() => _channel.invokeMethod<bool>('stop');

  Future<void> pause() => _channel.invokeMethod<bool>('pause');

  Future<void> resume() => _channel.invokeMethod<bool>('resume');

  /// Re-reads state after the app comes back to the foreground.
  Future<void> sync() async {
    try {
      final s = await _channel.invokeMapMethod<String, Object?>('status');
      if (s == null) return;
      final recording = s['recording'] == true;
      _elapsed = Duration(milliseconds: (s['elapsedMs'] as int?) ?? 0);
      if (!recording && _state != PhoneRecorderState.starting) {
        _set(PhoneRecorderState.idle);
      } else if (recording) {
        _set(s['paused'] == true ? PhoneRecorderState.paused : PhoneRecorderState.recording);
      }
    } catch (_) {}
    await refresh();
  }

  Future<void> refresh() async {
    try {
      final list = await _channel.invokeListMethod<Object?>('list') ?? const [];
      _recordings = list.map(PhoneRecording.fromMap).whereType<PhoneRecording>().toList();
      notifyListeners();
    } catch (_) {}
  }

  Future<Uint8List?> thumbnail(String uri) => _thumbs.putIfAbsent(
        uri,
        () => _channel.invokeMethod<Uint8List>('thumbnail', {'uri': uri}).catchError((_) => null),
      );

  Future<void> open(PhoneRecording r) => _channel.invokeMethod<bool>('open', {'uri': r.uri});

  Future<void> share(PhoneRecording r) => _channel.invokeMethod<bool>('share', {'uri': r.uri});

  Future<bool> delete(PhoneRecording r) async {
    final ok = await _channel.invokeMethod<bool>('delete', {'uri': r.uri}) ?? false;
    if (ok) {
      _thumbs.remove(r.uri);
      await refresh();
    }
    return ok;
  }

  Future<String?> filesDir() => _channel.invokeMethod<String>('filesDir');

  Future<Object?> _onEvent(MethodCall call) async {
    final data = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'started':
        _elapsed = Duration.zero;
        _set(PhoneRecorderState.recording);
      case 'paused':
        _set(PhoneRecorderState.paused);
      case 'resumed':
        _set(PhoneRecorderState.recording);
      case 'finished':
        _lastStoppedAtLimit = data['limit'] == true;
        await refresh();
        _set(PhoneRecorderState.idle);
      case 'micDenied':
        _message = 'Microphone access was not allowed, so this recording has no sound.';
        notifyListeners();
      case 'error':
        _message = data['message'] is String ? data['message'] as String : 'Recording failed.';
        _set(PhoneRecorderState.idle);
    }
    return null;
  }

  void _set(PhoneRecorderState s) {
    _state = s;
    _ticker?.cancel();
    if (s == PhoneRecorderState.recording) {
      // Follow the service's clock (it excludes paused time).
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        try {
          final st = await _channel.invokeMapMethod<String, Object?>('status');
          _elapsed = Duration(milliseconds: (st?['elapsedMs'] as int?) ?? _elapsed.inMilliseconds);
          notifyListeners();
        } catch (_) {}
      });
    }
    notifyListeners();
  }
}
