import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';
import 'app_update.dart';
import 'disk_space.dart';
import 'draft_store.dart';
import 'pro_service.dart';

enum HelpKind { problem, question, idea }

/// "Windows 11 (10.0.22631)" etc.
String describeSystem() => '${Platform.operatingSystem} ${Platform.operatingSystemVersion}'.trim();

/// What helps us answer: version, system, Pro, space, and the recent log.
/// No recordings, file names of videos, or licence keys.
String helpDetails() {
  final store = DraftStore.instance;
  final pro = ProService.instance;
  return [
    'App: $appVersion (build $appBuild)',
    'System: ${describeSystem()}',
    'Processors: ${Platform.numberOfProcessors}',
    'Pro: ${pro.isPro ? 'yes (${pro.license?.plan.name})' : 'no'}',
    'Recordings: ${store.drafts.length}${store.bytes == null ? '' : ', ${formatBytes(store.bytes!)}'}',
    if (store.freeBytes != null) 'Free space: ${formatBytes(store.freeBytes!)}',
    '',
    'Recent log:',
    ...AppLogger.recent.map(_scrub),
  ].join('\n');
}

/// Hides licence keys and the user's home folder name in log lines.
String _scrub(String line) {
  var out = line.replaceAll(RegExp(r'SR-[A-Z0-9-]{8,}'), 'SR-…');
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home != null && home.length > 3) out = out.replaceAll(home, '~');
  return out;
}

class HelpException implements Exception {
  HelpException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sends a "Get help" message to us (it shows in the admin dashboard and
/// is emailed to the team).
Future<void> sendHelpRequest({
  required HelpKind kind,
  required String message,
  String? email,
  bool includeDetails = true,
  String apiBase = proApiBase,
  HttpClient Function()? httpClient,
}) async {
  final client = (httpClient ?? HttpClient.new)();
  try {
    final request = await client.postUrl(Uri.parse('$apiBase/api/support')).timeout(const Duration(seconds: 15));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'kind': kind.name,
      'message': message,
      if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      'source': 'app',
      'appVersion': appVersion,
      'os': describeSystem(),
      if (includeDetails) 'details': helpDetails(),
    }));
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 400) {
      String? error;
      try {
        final json = jsonDecode(text);
        if (json is Map && json['error'] is String) error = json['error'] as String;
      } catch (_) {}
      throw HelpException(error ?? 'Couldn’t send it (error ${response.statusCode}). Try again in a minute.');
    }
    AppLogger.info('Help request sent');
  } on HelpException {
    rethrow;
  } on TimeoutException {
    throw HelpException('No answer from our server. Check your internet connection and try again.');
  } on SocketException {
    throw HelpException('You seem to be offline. Connect to the internet and try again.');
  } on HandshakeException {
    throw HelpException('A secure connection couldn’t be made. Check your network, or the computer’s date and time.');
  } finally {
    client.close(force: true);
  }
}
