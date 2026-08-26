import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'app_logger.dart';
import 'linux_desktop.dart';

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

  Future<File?> captureTo(File destination, {String parentWindow = ''}) async {
    DBusClient? client;
    StreamSubscription<DBusSignal>? subscription;
    DBusObjectPath? predictedPath;
    try {
      client = DBusClient.session();
      await client.ping();

      final token = 'sr${DateTime.now().microsecondsSinceEpoch}';
      predictedPath = DBusObjectPath(
        portalRequestObjectPath(
          uniqueName: client.uniqueName,
          handleToken: token,
        ),
      );

      final completer = Completer<DBusSignal>();
      subscription = DBusSignalStream(
        client,
        interface: 'org.freedesktop.portal.Request',
        name: 'Response',
      ).listen((signal) {
        if (completer.isCompleted) {
          return;
        }
        if (signal.path == predictedPath ||
            signal.path.value.startsWith(
              '/org/freedesktop/portal/desktop/request/',
            )) {
          completer.complete(signal);
        }
      });
      // Let the D-Bus match rule register before the portal replies.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final portal = DBusRemoteObject(
        client,
        name: 'org.freedesktop.portal.Desktop',
        path: DBusObjectPath('/org/freedesktop/portal/desktop'),
      );

      await portal.callMethod(
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

      final signal = await completer.future.timeout(timeout);
      if (signal.values.length < 2) {
        AppLogger.warn('XDG screenshot portal returned an empty Response');
        return null;
      }
      final code = signal.values[0].asUint32();
      if (code != 0) {
        AppLogger.warn('XDG screenshot portal Response code $code');
        return null;
      }
      final results = signal.values[1].asStringVariantDict();
      final path = filePathFromPortalUri(results['uri']?.asString());
      if (path == null) {
        AppLogger.warn('XDG screenshot portal had no file uri: $results');
        return null;
      }
      final source = File(path);
      if (!await source.exists() || await source.length() <= 64) {
        AppLogger.warn('XDG screenshot portal file missing or empty: $path');
        return null;
      }
      if (source.absolute.path != destination.absolute.path) {
        await source.copy(destination.path);
      }
      if (await destination.exists() && await destination.length() > 64) {
        AppLogger.info('Snapshot via XDG screenshot portal: ${destination.path}');
        return destination;
      }
    } on TimeoutException {
      AppLogger.warn('XDG screenshot portal timed out waiting for permission');
      await _closeRequest(client, predictedPath);
    } catch (error, stack) {
      AppLogger.warn('XDG screenshot portal failed: $error\n$stack');
    } finally {
      await subscription?.cancel();
      await client?.close();
    }
    return null;
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
