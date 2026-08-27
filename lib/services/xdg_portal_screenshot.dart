import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'app_logger.dart';
import 'linux_desktop.dart';

enum PortalCaptureStatus { success, cancelled, timeout, failed }

class PortalCaptureResult {
  const PortalCaptureResult(this.status, [this.file]);

  final PortalCaptureStatus status;
  final File? file;

  bool get hasFile => file != null;
  bool get success => status == PortalCaptureStatus.success && file != null;
}

PortalCaptureStatus portalStatusFromResponseCode(int code) {
  switch (code) {
    case 0:
      return PortalCaptureStatus.success;
    case 1:
      return PortalCaptureStatus.cancelled;
    default:
      return PortalCaptureStatus.failed;
  }
}

/// Completes only for a Response on [predictedPath] or the `o` returned by
/// `Screenshot`. Other Request objects are ignored so a hide-first `Close`
/// cannot cancel a later focused wait.
class PortalRequestWaiter {
  PortalRequestWaiter({required this.predictedPath});

  final DBusObjectPath predictedPath;
  DBusObjectPath? returnedHandle;
  final Completer<DBusSignal> _completer = Completer<DBusSignal>();
  final List<DBusSignal> _buffered = [];

  Future<DBusSignal> get future => _completer.future;

  bool get isCompleted => _completer.isCompleted;

  bool matches(DBusObjectPath path) {
    return path == predictedPath ||
        (returnedHandle != null && path == returnedHandle);
  }

  void onSignal(DBusSignal signal) {
    if (_completer.isCompleted) {
      return;
    }
    if (matches(signal.path)) {
      _completer.complete(signal);
    } else {
      _buffered.add(signal);
    }
  }

  void setReturnedHandle(DBusObjectPath path) {
    returnedHandle = path;
    if (_completer.isCompleted) {
      return;
    }
    for (final signal in _buffered) {
      if (matches(signal.path)) {
        _completer.complete(signal);
        return;
      }
    }
  }

  /// Times out with a single [closeOnTimeout]. Does not Close on cancelled.
  Future<PortalCaptureResult> waitForResult({
    required Duration timeout,
    required Future<void> Function() closeOnTimeout,
    required Future<PortalCaptureResult> Function(DBusSignal signal) mapResponse,
  }) async {
    try {
      final signal = await future.timeout(timeout);
      return await mapResponse(signal);
    } on TimeoutException {
      await closeOnTimeout();
      return const PortalCaptureResult(PortalCaptureStatus.timeout);
    } catch (error, stack) {
      AppLogger.warn('XDG screenshot portal failed: $error\n$stack');
      return const PortalCaptureResult(PortalCaptureStatus.failed);
    }
  }
}

/// Still capture via `org.freedesktop.portal.Screenshot`.
///
/// GNOME Shell's private Screenshot D-Bus API is denied to regular apps
/// ("Screenshot is not allowed"). The XDG portal is the supported path on
/// modern GNOME/KDE Wayland.
class XdgPortalScreenshot {
  XdgPortalScreenshot({
    this.timeout = const Duration(seconds: 45),
  });

  final Duration timeout;

  Future<PortalCaptureResult> captureTo(
    File destination, {
    String parentWindow = '',
    Duration? timeout,
  }) async {
    final wait = timeout ?? this.timeout;
    DBusClient? client;
    StreamSubscription<DBusSignal>? subscription;
    PortalRequestWaiter? waiter;
    try {
      client = DBusClient.session();
      await client.ping();

      final token = 'sr${DateTime.now().microsecondsSinceEpoch}';
      final predictedPath = DBusObjectPath(
        portalRequestObjectPath(
          uniqueName: client.uniqueName,
          handleToken: token,
        ),
      );
      waiter = PortalRequestWaiter(predictedPath: predictedPath);

      subscription = DBusSignalStream(
        client,
        interface: 'org.freedesktop.portal.Request',
        name: 'Response',
      ).listen(waiter.onSignal);
      // Let the D-Bus match rule register before the portal replies.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final portal = DBusRemoteObject(
        client,
        name: 'org.freedesktop.portal.Desktop',
        path: DBusObjectPath('/org/freedesktop/portal/desktop'),
      );

      final reply = await portal.callMethod(
        'org.freedesktop.portal.Screenshot',
        'Screenshot',
        [
          DBusString(parentWindow),
          DBusDict.stringVariant({
            'handle_token': DBusString(token),
            'interactive': const DBusBoolean(false),
            'modal': const DBusBoolean(false),
          }),
        ],
        replySignature: DBusSignature('o'),
      );
      if (reply.values.isNotEmpty) {
        waiter.setReturnedHandle(reply.values.first.asObjectPath());
      }

      return await waiter.waitForResult(
        timeout: wait,
        closeOnTimeout: () => _closeRequest(client, predictedPath),
        mapResponse: (signal) => _resultFromSignal(signal, destination),
      );
    } on TimeoutException {
      AppLogger.warn('XDG screenshot portal timed out waiting for permission');
      await _closeRequest(client, waiter?.predictedPath);
      return const PortalCaptureResult(PortalCaptureStatus.timeout);
    } catch (error, stack) {
      AppLogger.warn('XDG screenshot portal failed: $error\n$stack');
      return const PortalCaptureResult(PortalCaptureStatus.failed);
    } finally {
      await subscription?.cancel();
      await client?.close();
    }
  }

  Future<PortalCaptureResult> _resultFromSignal(
    DBusSignal signal,
    File destination,
  ) async {
    if (signal.values.length < 2) {
      AppLogger.warn('XDG screenshot portal returned an empty Response');
      return const PortalCaptureResult(PortalCaptureStatus.failed);
    }
    final code = signal.values[0].asUint32();
    final status = portalStatusFromResponseCode(code);
    if (status != PortalCaptureStatus.success) {
      AppLogger.warn('XDG screenshot portal Response code $code');
      return PortalCaptureResult(status);
    }
    final results = signal.values[1].asStringVariantDict();
    final path = filePathFromPortalUri(results['uri']?.asString());
    if (path == null) {
      AppLogger.warn('XDG screenshot portal had no file uri: $results');
      return const PortalCaptureResult(PortalCaptureStatus.failed);
    }
    final source = File(path);
    if (!await source.exists() || await source.length() <= 64) {
      AppLogger.warn('XDG screenshot portal file missing or empty: $path');
      return const PortalCaptureResult(PortalCaptureStatus.failed);
    }
    if (source.absolute.path != destination.absolute.path) {
      await source.copy(destination.path);
    }
    if (await destination.exists() && await destination.length() > 64) {
      AppLogger.info('Snapshot via XDG screenshot portal: ${destination.path}');
      return PortalCaptureResult(PortalCaptureStatus.success, destination);
    }
    return const PortalCaptureResult(PortalCaptureStatus.failed);
  }

  Future<void> _closeRequest(
    DBusClient? client,
    DBusObjectPath? requestPath,
  ) async {
    if (client == null || requestPath == null) {
      return;
    }
    try {
      await DBusRemoteObject(
        client,
        name: 'org.freedesktop.portal.Desktop',
        path: requestPath,
      ).callMethod(
        'org.freedesktop.portal.Request',
        'Close',
        const [],
        replySignature: DBusSignature(''),
      );
    } catch (error) {
      AppLogger.debug('Could not close screenshot portal request: $error');
    }
  }
}
