import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_folders.dart';
import 'app_logger.dart';
import 'support_link.dart';

/// The website that sells Pro and checks licences.
const String proApiBase = String.fromEnvironment('PRO_API', defaultValue: 'https://screenrecorderapp.vercel.app');

enum ProPlan { monthly, lifetime }

enum ProCurrency { ngn, usd }

extension ProCurrencyCode on ProCurrency {
  String get code => this == ProCurrency.ngn ? 'NGN' : 'USD';
}

/// Display prices (Bachs charges what's on its products; the server owns them).
String proPrice(ProPlan plan, ProCurrency currency) => switch ((plan, currency)) {
      (ProPlan.monthly, ProCurrency.ngn) => '₦2,000',
      (ProPlan.monthly, ProCurrency.usd) => r'$5',
      (ProPlan.lifetime, ProCurrency.ngn) => '₦50,000',
      (ProPlan.lifetime, ProCurrency.usd) => r'$100',
    };

/// A licence as the server describes it.
@immutable
class ProLicense {
  const ProLicense({
    required this.key,
    required this.active,
    required this.plan,
    required this.status,
    this.renews,
    this.endsAt,
    this.email,
    this.canManage = false,
  });

  final String key;
  final bool active;
  final ProPlan plan;
  final String status;
  final DateTime? renews;
  final DateTime? endsAt;
  final String? email;
  final bool canManage;

  static ProLicense? fromJson(Map<String, dynamic> json) {
    final key = json['key'];
    if (key is! String || !isLicenseKey(key)) return null;
    return ProLicense(
      key: key,
      active: json['active'] == true,
      plan: json['plan'] == 'lifetime' ? ProPlan.lifetime : ProPlan.monthly,
      status: json['status'] is String ? json['status'] as String : 'active',
      renews: DateTime.tryParse('${json['renews']}'),
      endsAt: DateTime.tryParse('${json['endsAt']}'),
      email: json['email'] is String ? json['email'] as String : null,
      canManage: json['canManage'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'active': active,
        'plan': plan.name,
        'status': status,
        'renews': renews?.toIso8601String(),
        'endsAt': endsAt?.toIso8601String(),
        'email': email,
        'canManage': canManage,
      };
}

bool isLicenseKey(String value) => RegExp(r'^SR-[A-Z2-7]{4}(-[A-Z2-7]{4}){3}$').hasMatch(value);

/// Normalises what people paste (spaces, lower case, missing dashes).
String? normalizeLicenseKey(String input) {
  final raw = input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final body = raw.startsWith('SR') ? raw.substring(2) : raw;
  if (body.length != 16) return null;
  final key = 'SR-${body.substring(0, 4)}-${body.substring(4, 8)}-${body.substring(8, 12)}-${body.substring(12)}';
  return isLicenseKey(key) ? key : null;
}

class ProException implements Exception {
  ProException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Pro status for this computer: the free recording limit, the licence, and
/// buying Pro through the website (Bachs checkout).
class ProService extends ChangeNotifier {
  ProService({
    String apiBase = proApiBase,
    HttpClient Function()? httpClient,
    Future<bool> Function(String url)? open,
    File? storeFile,
    DateTime Function()? clock,
    this.pollEvery = const Duration(seconds: 3),
  })  : _api = apiBase,
        _http = httpClient ?? HttpClient.new,
        _open = open ?? openUrl,
        _file = storeFile,
        _now = clock ?? DateTime.now;

  static final ProService instance = ProService();

  final String _api;
  final HttpClient Function() _http;
  final Future<bool> Function(String url) _open;
  final File? _file;
  final DateTime Function() _now;

  /// How often to ask whether a purchase has been paid.
  final Duration pollEvery;

  ProLicense? _license;
  DateTime? _checkedAt;
  bool _enabled = false;
  int _freeLimitSeconds = 180;
  String? _pendingActivation;
  ProPlan? _pendingPlan;
  bool _waiting = false;
  Timer? _refresh;
  bool _loaded = false;

  /// The last recording was stopped by the free limit.
  bool stoppedAtLimit = false;

  ProLicense? get license => _license;
  bool get paymentsEnabled => _enabled;
  bool get waitingForPayment => _waiting;
  ProPlan? get pendingPlan => _pendingPlan;
  Duration get freeLimit => Duration(seconds: _freeLimitSeconds);

  /// Pro unlocks unlimited recording. A licence checked recently keeps
  /// working offline: lifetime always, monthly for 14 days.
  bool get isPro {
    final l = _license;
    if (l == null || !l.active) return false;
    if (l.plan == ProPlan.lifetime) return true;
    final checked = _checkedAt;
    return checked != null && _now().difference(checked) < const Duration(days: 14);
  }

  /// Longest recording allowed right now, or null for no limit. The limit
  /// only applies once payments are switched on, so nobody is limited before
  /// they can pay.
  Duration? get recordingLimit => (_enabled && !isPro) ? freeLimit : null;

  File? get _store {
    if (_file != null) return _file;
    final folder = appSettingsFolder();
    return folder == null ? null : File(p.join(folder.path, 'pro.json'));
  }

  /// Loads the saved licence, then refreshes from the server in the background.
  Future<void> start() async {
    await _load();
    unawaited(refresh());
    if (_pendingActivation != null) unawaited(waitForPayment());
    _refresh ??= Timer.periodic(const Duration(hours: 6), (_) => refresh());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  /// Asks the server for plan settings and the licence's current state.
  Future<void> refresh() async {
    try {
      final plans = await _get('/api/plans');
      _enabled = plans['enabled'] == true;
      final limit = plans['freeLimitSeconds'];
      if (limit is int && limit > 0) _freeLimitSeconds = limit;
    } catch (error) {
      AppLogger.debug('Pro plans check failed: $error');
    }
    final key = _license?.key;
    if (key != null) {
      try {
        final json = await _get('/api/license?key=${Uri.encodeQueryComponent(key)}');
        final updated = ProLicense.fromJson(json);
        if (updated != null) {
          _license = updated;
          _checkedAt = _now();
        }
      } on ProException catch (error) {
        // The server says the key is unknown: forget it.
        if (error.message.contains('No licence')) _license = null;
      } catch (error) {
        AppLogger.debug('Licence check failed: $error');
      }
    }
    await _save();
    notifyListeners();
  }

  /// Starts a purchase: creates a checkout on the website, opens it in the
  /// browser, and waits for the payment to be confirmed.
  Future<void> buy({
    required ProPlan plan,
    required ProCurrency currency,
    required String email,
    required String name,
  }) async {
    final activation = _newActivation();
    final json = await _post('/api/checkout', {
      'plan': plan.name,
      'currency': currency.code,
      'email': email.trim(),
      'name': name.trim(),
      'activation': activation,
    });
    final url = json['checkoutUrl'];
    if (url is! String || !url.startsWith('https://')) {
      throw ProException('The payment page could not be opened. Try again in a minute.');
    }
    _pendingActivation = activation;
    _pendingPlan = plan;
    await _save();
    if (!await _open(url)) {
      throw ProException('Could not open your browser. Open this link to pay: $url');
    }
    unawaited(waitForPayment());
  }

  /// Polls until the pending purchase is paid (up to 30 minutes per call).
  Future<bool> waitForPayment({Duration? every, Duration giveUp = const Duration(minutes: 30)}) async {
    final interval = every ?? pollEvery;
    final activation = _pendingActivation;
    if (activation == null || _waiting) return false;
    _waiting = true;
    notifyListeners();
    final stop = _now().add(giveUp);
    try {
      while (_pendingActivation == activation && _now().isBefore(stop)) {
        try {
          final json = await _get('/api/license?activation=${Uri.encodeQueryComponent(activation)}');
          if (json['pending'] != true) {
            final licence = ProLicense.fromJson(json);
            if (licence != null) {
              _license = licence;
              _checkedAt = _now();
              _pendingActivation = null;
              _pendingPlan = null;
              stoppedAtLimit = false;
              await _save();
              return true;
            }
          }
        } on ProException catch (error) {
          if (error.message.contains('Unknown purchase')) {
            _pendingActivation = null;
            break;
          }
        } catch (_) {
          // Offline for a moment: keep trying.
        }
        await Future<void>.delayed(interval);
      }
      return false;
    } finally {
      _waiting = false;
      notifyListeners();
    }
  }

  /// Stops waiting for a purchase (the user closed the checkout).
  Future<void> cancelPurchase() async {
    _pendingActivation = null;
    _pendingPlan = null;
    await _save();
    notifyListeners();
  }

  /// Unlocks Pro with a licence key bought on the website.
  Future<ProLicense> activate(String input) async {
    final key = normalizeLicenseKey(input);
    if (key == null) {
      throw ProException("That doesn't look like a licence key. It looks like SR-XXXX-XXXX-XXXX-XXXX.");
    }
    final json = await _get('/api/license?key=${Uri.encodeQueryComponent(key)}');
    final licence = ProLicense.fromJson(json);
    if (licence == null) throw ProException('That licence could not be read. Try again.');
    if (!licence.active) {
      throw ProException(licence.plan == ProPlan.monthly
          ? 'This monthly plan has ended. Renew it to keep using Pro.'
          : 'This licence is not active.');
    }
    _license = licence;
    _checkedAt = _now();
    stoppedAtLimit = false;
    await _save();
    notifyListeners();
    return licence;
  }

  /// Opens the Bachs customer portal to change or cancel a monthly plan.
  Future<void> manageSubscription() async {
    final key = _license?.key;
    if (key == null) return;
    final json = await _post('/api/license', {'action': 'portal', 'key': key});
    final url = json['url'];
    if (url is! String || !await _open(url)) {
      throw ProException('Could not open the subscription page.');
    }
  }

  /// Removes the licence from this computer (it still works elsewhere).
  Future<void> signOut() async {
    _license = null;
    _checkedAt = null;
    await _save();
    notifyListeners();
  }

  // ---- storage ---------------------------------------------------------------

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = _store;
      if (file == null || !await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return;
      final l = json['license'];
      _license = l is Map<String, dynamic> ? ProLicense.fromJson(l) : null;
      _checkedAt = DateTime.tryParse('${json['checkedAt']}');
      _enabled = json['enabled'] == true;
      final limit = json['freeLimitSeconds'];
      if (limit is int && limit > 0) _freeLimitSeconds = limit;
      final pending = json['pendingActivation'];
      _pendingActivation = pending is String && pending.length >= 24 ? pending : null;
      _pendingPlan = json['pendingPlan'] == 'lifetime'
          ? ProPlan.lifetime
          : json['pendingPlan'] == 'monthly'
              ? ProPlan.monthly
              : null;
      notifyListeners();
    } catch (error) {
      AppLogger.debug('Could not read pro.json: $error');
    }
  }

  Future<void> _save() async {
    try {
      final file = _store;
      if (file == null) return;
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'license': _license?.toJson(),
        'checkedAt': _checkedAt?.toIso8601String(),
        'enabled': _enabled,
        'freeLimitSeconds': _freeLimitSeconds,
        'pendingActivation': _pendingActivation,
        'pendingPlan': _pendingPlan?.name,
      }));
    } catch (error) {
      AppLogger.debug('Could not save pro.json: $error');
    }
  }

  // ---- HTTP ------------------------------------------------------------------

  Future<Map<String, dynamic>> _get(String path) => _send('GET', path, null);

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) => _send('POST', path, body);

  Future<Map<String, dynamic>> _send(String method, String path, Map<String, dynamic>? body) async {
    final client = _http();
    try {
      final request = await client.openUrl(method, Uri.parse('$_api$path')).timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(const Duration(seconds: 20));
      final text = await response.transform(utf8.decoder).join();
      Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(text);
        json = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } catch (_) {
        json = <String, dynamic>{};
      }
      if (response.statusCode >= 400) {
        final message = json['error'];
        throw ProException(message is String && message.isNotEmpty
            ? message
            : 'Something went wrong (${response.statusCode}). Try again in a minute.');
      }
      return json;
    } on ProException {
      rethrow;
    } on TimeoutException {
      throw ProException('No answer from the server. Check your internet connection.');
    } on SocketException {
      throw ProException('No internet connection.');
    } finally {
      client.close(force: true);
    }
  }

  static String _newActivation() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
