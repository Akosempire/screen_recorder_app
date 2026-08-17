import 'dart:async';

import 'package:dbus/dbus.dart';

import '../models/recorder_exception.dart';
import 'app_logger.dart';
import 'linux_desktop.dart';

/// GNOME Shell screencast session.
///
/// The service watches the D-Bus unique name of the caller and **stops the
/// pipeline when that name vanishes**. A one-shot `gdbus call` therefore
/// records a single frame and GNOME shows "Screencast ended unexpectedly".
/// This client keeps the session-bus connection open until [stop]/[close].
abstract class GnomeScreencastSession {
  Future<void> connect();

  Future<String> startArea({
    required int x,
    required int y,
    required int width,
    required int height,
    required String filePathStem,
    int fps = 30,
  });

  Future<void> stop();

  Future<void> close();

  String? get fatalError;
}

class DbusGnomeScreencastSession implements GnomeScreencastSession {
  DBusClient? _client;
  DBusRemoteObject? _object;
  StreamSubscription<DBusSignal>? _errorSub;
  String? _fatalError;
  bool _recording = false;

  static const _dest = 'org.gnome.Shell.Screencast';
  static const _iface = 'org.gnome.Shell.Screencast';

  @override
  String? get fatalError => _fatalError;

  @override
  Future<void> connect() async {
    if (_client != null) {
      return;
    }
    final client = DBusClient.session();
    await client.ping();
    final object = DBusRemoteObject(
      client,
      name: _dest,
      path: DBusObjectPath('/org/gnome/Shell/Screencast'),
    );
    _client = client;
    _object = object;
    _fatalError = null;
    _errorSub = DBusRemoteObjectSignalStream(
      object: object,
      interface: _iface,
      name: 'Error',
    ).listen((signal) {
      final message = signal.values.length > 1
          ? signal.values[1].asString()
          : 'GNOME screencast error';
      _fatalError = message;
      AppLogger.error('GNOME Screencast Error signal: $message');
    });
    // Let the D-Bus match rule register before the first method call.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    AppLogger.info('GNOME Screencast D-Bus session connected');
  }

  @override
  Future<String> startArea({
    required int x,
    required int y,
    required int width,
    required int height,
    required String filePathStem,
    int fps = 30,
  }) async {
    await connect();
    final object = _object;
    if (object == null) {
      throw const RecorderException(
        userMessage: 'Could not connect to the GNOME screencast service.',
      );
    }
    _fatalError = null;
    AppLogger.info(
      'GNOME ScreencastArea ${width}x$height+$x+$y stem=$filePathStem',
    );
    try {
      final result = await object.callMethod(
        _iface,
        'ScreencastArea',
        [
          DBusInt32(x),
          DBusInt32(y),
          DBusInt32(width),
          DBusInt32(height),
          DBusString(filePathStem),
          DBusDict.stringVariant({
            'framerate': DBusInt32(fps),
            'draw-cursor': const DBusBoolean(true),
            // Skip GNOME's DMABuf/GL encoder probes; they can "start" and
            // still write zero bytes when OpenH264 is not installed.
            'pipeline': const DBusString(gnomeSoftwareWebmPipeline),
          }),
        ],
        replySignature: DBusSignature('bs'),
      );
      final success = result.returnValues[0].asBoolean();
      final path = result.returnValues[1].asString();
      if (!success) {
        throw const RecorderException(
          userMessage:
              'GNOME could not start a region recording. If a permission prompt appeared, allow screen recording and try again.',
        );
      }
      _recording = true;
      AppLogger.info('GNOME Screencast writing to $path');
      return path;
    } on RecorderException {
      rethrow;
    } on DBusMethodResponseException catch (error, stack) {
      AppLogger.error('GNOME ScreencastArea D-Bus error', error, stack);
      throw RecorderException(
        userMessage:
            'GNOME could not start a region recording. If a permission prompt appeared, allow screen recording and try again.',
        technicalDetails: error.toString(),
      );
    } catch (error, stack) {
      AppLogger.error('GNOME ScreencastArea failed', error, stack);
      throw RecorderException(
        userMessage: 'GNOME could not start a region recording.',
        technicalDetails: error.toString(),
      );
    }
  }

  @override
  Future<void> stop() async {
    final object = _object;
    if (object == null || !_recording) {
      _recording = false;
      return;
    }
    try {
      await object.callMethod(
        _iface,
        'StopScreencast',
        const [],
        replySignature: DBusSignature('b'),
      );
    } on DBusMethodResponseException catch (error, stack) {
      AppLogger.debug('GNOME StopScreencast: $error\n$stack');
    } finally {
      _recording = false;
    }
  }

  @override
  Future<void> close() async {
    if (_recording) {
      await stop();
    }
    await _errorSub?.cancel();
    _errorSub = null;
    _object = null;
    final client = _client;
    _client = null;
    if (client != null) {
      await client.close();
    }
  }
}
