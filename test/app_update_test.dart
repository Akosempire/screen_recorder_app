import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/services/app_update.dart';

void main() {
  group('UpdateInfo.parse', () {
    test('reads the CI manifest', () {
      final info = UpdateInfo.parse(jsonEncode({
        'build': 58,
        'version': '1.0.58',
        'installer': 'https://github.com/x/y/releases/download/windows-latest/ScreenRecorder-Setup.exe',
        'commit': 'abc',
      }));
      expect(info!.build, 58);
      expect(info.version, '1.0.58');
    });

    test('rejects bad or unsafe manifests', () {
      expect(UpdateInfo.parse('not json'), isNull);
      expect(UpdateInfo.parse(jsonEncode({'build': '58', 'installer': 'https://x'})), isNull);
      expect(UpdateInfo.parse(jsonEncode({'build': 58, 'installer': 'http://evil.example/x.exe'})), isNull);
      expect(UpdateInfo.parse(jsonEncode({'build': 58, 'installer': 'file:///C:/x.exe'})), isNull);
    });
  });

  group('AppUpdateService', () {
    late HttpServer server;
    late String base;
    const manifestBuild = 60;
    var installerBytes = <int>[0x4D, 0x5A, ...List.filled(2 * 1024 * 1024, 7)];

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        if (req.uri.path == '/version.json') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'build': manifestBuild,
            'version': '1.0.$manifestBuild',
            'installer': '$base/setup.exe',
            'downloads': {
              'macos': '$base/ScreenRecorder-macOS.dmg',
              'linux_deb': '$base/ScreenRecorder-Linux-x64.deb',
              'linux_tar': '$base/ScreenRecorder-Linux-x64.tar.gz',
              'evil': 'http://evil.example/x',
            },
          }));
        } else if (req.uri.path == '/setup.exe') {
          req.response.contentLength = installerBytes.length;
          req.response.add(installerBytes);
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('finds a newer build, downloads it and hands it to the installer', () async {
      String? launched;
      final service = AppUpdateService(
        currentBuild: 57,
        manifestUrl: '$base/version.json',
        launchInstaller: (path) async => launched = path,
        installsInPlace: true,
      );
      final info = await service.check();
      expect(info!.build, 60);
      expect(service.updateAvailable, isTrue);
      expect(service.status, UpdateStatus.available);

      await service.install();
      expect(service.status, UpdateStatus.installing);
      expect(service.progress, 1);
      expect(launched, endsWith('ScreenRecorder-Setup-60.exe'));
      expect(File(launched!).lengthSync(), installerBytes.length);
      File(launched!).deleteSync();
    });

    test('same or older build is not an update', () async {
      final service = AppUpdateService(currentBuild: 60, manifestUrl: '$base/version.json');
      expect(await service.check(), isNull);
      expect(service.updateAvailable, isFalse);
    });

    test('a download that is not an installer fails cleanly', () async {
      installerBytes = utf8.encode('<html>not found</html>');
      var launched = false;
      final service = AppUpdateService(
        currentBuild: 1,
        manifestUrl: '$base/version.json',
        launchInstaller: (_) async => launched = true,
        installsInPlace: true,
      );
      await service.check();
      await service.install();
      expect(launched, isFalse);
      expect(service.status, UpdateStatus.failed);
      expect(service.error, isNotNull);
      installerBytes = [0x4D, 0x5A, ...List.filled(2 * 1024 * 1024, 7)];
    });

    test('offline: no update, no error', () async {
      final service = AppUpdateService(currentBuild: 1, manifestUrl: 'http://127.0.0.1:1/version.json');
      expect(await service.check(), isNull);
      expect(service.updateAvailable, isFalse);
    });

    test('macOS and Linux open the right download in the browser', () async {
      for (final (os, expected) in [
        ('macos', 'ScreenRecorder-macOS.dmg'),
        ('linux', 'ScreenRecorder-Linux-x64.tar.gz'),
      ]) {
        String? opened;
        final service = AppUpdateService(
          currentBuild: 57,
          manifestUrl: '$base/version.json',
          installsInPlace: false,
          os: os,
          openUrl: (url) async => opened = url,
        );
        await service.check();
        await service.install();
        expect(opened, endsWith(expected), reason: os);
        expect(service.openedDownload, isTrue);
        expect(service.status, UpdateStatus.available);
      }
    });

    test('dev builds (APP_BUILD 0) never look for updates', () {
      expect(AppUpdateService(currentBuild: 0).enabled, isFalse);
    });
  });
}
