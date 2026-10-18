import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';

/// Build number baked in by CI (`--dart-define=APP_BUILD=<run number>`).
/// 0 for local/dev builds, which never look for updates.
const int appBuild = int.fromEnvironment('APP_BUILD');

/// Human version shown in the UI, e.g. 1.0.57.
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// Published by CI next to the installer on the latest GitHub release.
const String updateManifestUrl =
    'https://github.com/Akosempire/screen_recorder_app/releases/latest/download/version.json';

/// Installers are only fetched over HTTPS (plain HTTP is allowed for a local
/// test server).
bool _trustedUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.scheme == 'https') return true;
  return uri.scheme == 'http' && (uri.host == '127.0.0.1' || uri.host == 'localhost');
}

/// What the latest release says about itself.
@immutable
class UpdateInfo {
  const UpdateInfo({required this.build, required this.version, required this.installerUrl});

  final int build;
  final String version;
  final String installerUrl;

  /// Parses `version.json`. Returns null if it is not usable.
  static UpdateInfo? parse(String body) {
    try {
      final data = jsonDecode(body);
      if (data is! Map) return null;
      final build = data['build'];
      final installer = data['installer'];
      if (build is! int || installer is! String || !_trustedUrl(installer)) return null;
      return UpdateInfo(
        build: build,
        version: data['version'] is String ? data['version'] as String : '1.0.$build',
        installerUrl: installer,
      );
    } catch (_) {
      return null;
    }
  }
}

enum UpdateStatus { idle, available, downloading, installing, failed }

/// Checks GitHub for a newer build and installs it in place: downloads the
/// new installer, starts it silently, and quits so files can be replaced.
/// The installer reopens the app when it finishes (see screen_recorder.iss).
class AppUpdateService extends ChangeNotifier {
  AppUpdateService({
    this.currentBuild = appBuild,
    this.manifestUrl = updateManifestUrl,
    HttpClient Function()? httpClient,
    Future<void> Function(String installer)? launchInstaller,
  })  : _http = httpClient ?? HttpClient.new,
        _launch = launchInstaller ?? _launchAndQuit;

  static final AppUpdateService instance = AppUpdateService();

  final int currentBuild;
  final String manifestUrl;
  final HttpClient Function() _http;
  final Future<void> Function(String installer) _launch;

  UpdateStatus _status = UpdateStatus.idle;
  UpdateInfo? _latest;
  double _progress = 0;
  String? _error;
  Timer? _timer;

  UpdateStatus get status => _status;
  UpdateInfo? get latest => _latest;
  double get progress => _progress;
  String? get error => _error;
  bool get updateAvailable => _latest != null && _status != UpdateStatus.idle;

  /// Only installed Windows builds from CI update themselves.
  bool get enabled => Platform.isWindows && currentBuild > 0;

  /// First check shortly after start, then every 6 hours.
  void start({Duration firstDelay = const Duration(seconds: 8)}) {
    if (!enabled || _timer != null) return;
    _timer = Timer(firstDelay, () async {
      await check();
      _timer = Timer.periodic(const Duration(hours: 6), (_) => check());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Returns the newer release, or null when up to date / offline.
  Future<UpdateInfo?> check() async {
    if (_status == UpdateStatus.downloading || _status == UpdateStatus.installing) return _latest;
    final client = _http();
    try {
      final request = await client.getUrl(Uri.parse('$manifestUrl?t=${DateTime.now().millisecondsSinceEpoch}'));
      request.headers.set(HttpHeaders.userAgentHeader, 'ScreenRecorder/$currentBuild');
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      final info = UpdateInfo.parse(body);
      if (info != null && info.build > currentBuild) {
        _latest = info;
        if (_status == UpdateStatus.idle || _status == UpdateStatus.failed) {
          _status = UpdateStatus.available;
          _error = null;
        }
        notifyListeners();
        return info;
      }
      return null;
    } catch (error) {
      AppLogger.debug('Update check failed: $error');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads the new installer and hands over to it.
  Future<void> install() async {
    final info = _latest;
    if (info == null || _status == UpdateStatus.downloading || _status == UpdateStatus.installing) return;
    _status = UpdateStatus.downloading;
    _progress = 0;
    _error = null;
    notifyListeners();
    final client = _http();
    try {
      final target = File(p.join(Directory.systemTemp.path, 'ScreenRecorder-Setup-${info.build}.exe'));
      final request = await client.getUrl(Uri.parse(info.installerUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'ScreenRecorder/$currentBuild');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('Download failed (${response.statusCode})');
      }
      final total = response.contentLength;
      var received = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            _progress = received / total;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      if (!_looksLikeInstaller(target)) {
        throw const FileSystemException('The download was not a valid installer.');
      }
      _status = UpdateStatus.installing;
      _progress = 1;
      notifyListeners();
      await _launch(target.path);
    } catch (error) {
      AppLogger.warn('Update failed: $error');
      _status = UpdateStatus.failed;
      _error = 'The update could not be downloaded. Check your internet connection and try again.';
      notifyListeners();
    } finally {
      client.close(force: true);
    }
  }

  static bool _looksLikeInstaller(File file) {
    if (!file.existsSync() || file.lengthSync() < 1024 * 1024) return false;
    final raf = file.openSync();
    try {
      final head = raf.readSync(2);
      return head.length == 2 && head[0] == 0x4D && head[1] == 0x5A; // "MZ"
    } finally {
      raf.closeSync();
    }
  }

  /// Runs the installer without its wizard, then exits so it can replace the
  /// app's files. `/update=1` tells the installer to reopen the app afterwards.
  static Future<void> _launchAndQuit(String installer) async {
    await Process.start(
      installer,
      ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/update=1'],
      mode: ProcessStartMode.detached,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }
}
