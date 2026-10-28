import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/services/pro_service.dart';

/// A stand-in for the website's Pro API.
class _FakeApi {
  late HttpServer server;
  bool enabled = true;
  int claimsBeforePaid = 2;
  final checkouts = <Map<String, dynamic>>[];
  final licences = <String, Map<String, dynamic>>{};

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      Object reply = {};
      var status = 200;
      final q = req.uri.queryParameters;
      if (req.uri.path == '/api/plans') {
        reply = {'enabled': enabled, 'freeLimitSeconds': 180};
      } else if (req.uri.path == '/api/checkout' && req.method == 'POST') {
        final json = jsonDecode(body) as Map<String, dynamic>;
        checkouts.add(json);
        reply = {'checkoutUrl': 'https://sandbox-checkout.bachs.io/c/1', 'activation': json['activation']};
      } else if (req.uri.path == '/api/license' && q['activation'] != null) {
        if (claimsBeforePaid-- > 0) {
          reply = {'pending': true, 'plan': 'lifetime'};
        } else {
          reply = {'pending': false, 'active': true, 'key': 'SR-ABCD-EFGH-IJKL-MNOP', 'plan': 'lifetime', 'status': 'active', 'email': 'ad•@example.com'};
        }
      } else if (req.uri.path == '/api/license' && q['key'] != null) {
        final l = licences[q['key']];
        if (l == null) {
          status = 404;
          reply = {'error': 'No licence with that key.'};
        } else {
          reply = l;
        }
      } else {
        status = 404;
      }
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(reply));
      await req.response.close();
    });
  }
}

void main() {
  late _FakeApi api;
  late Directory dir;
  setUp(() async {
    api = _FakeApi();
    await api.start();
    dir = await Directory.systemTemp.createTemp('pro_test_');
  });
  tearDown(() async {
    await api.server.close(force: true);
    await dir.delete(recursive: true);
  });

  ProService service({DateTime Function()? clock, List<String>? opened}) => ProService(
        apiBase: api.base,
        storeFile: File('${dir.path}/pro.json'),
        open: (url) async {
          opened?.add(url);
          return true;
        },
        clock: clock,
        pollEvery: const Duration(milliseconds: 20),
      );

  test('no limit until payments are switched on', () async {
    api.enabled = false;
    final pro = service();
    await pro.refresh();
    expect(pro.paymentsEnabled, isFalse);
    expect(pro.recordingLimit, isNull);
    api.enabled = true;
    await pro.refresh();
    expect(pro.recordingLimit, const Duration(minutes: 3));
  });

  test('buying: opens checkout, waits for payment, then unlocks and remembers it', () async {
    final opened = <String>[];
    final pro = service(opened: opened);
    await pro.refresh();
    await pro.buy(plan: ProPlan.lifetime, currency: ProCurrency.ngn, email: 'ada@example.com', name: 'Ada');
    expect(opened.single, startsWith('https://sandbox-checkout.bachs.io/'));
    expect(api.checkouts.single['plan'], 'lifetime');
    expect(api.checkouts.single['currency'], 'NGN');
    expect((api.checkouts.single['activation'] as String).length, greaterThanOrEqualTo(24));

    // buy() keeps checking in the background until the payment is confirmed.
    expect(pro.waitingForPayment, isTrue);
    for (var i = 0; i < 100 && (!pro.isPro || pro.waitingForPayment); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(pro.isPro, isTrue);
    expect(pro.waitingForPayment, isFalse);
    expect(pro.recordingLimit, isNull);
    expect(pro.license!.key, 'SR-ABCD-EFGH-IJKL-MNOP');

    // A new instance (next app start) reads it back.
    final again = service();
    await again.start();
    expect(again.isPro, isTrue);
    again.dispose();
  });

  test('licence keys: pasted keys are cleaned up, unknown ones are rejected', () async {
    expect(normalizeLicenseKey(' sr-abcd efgh-ijkl-mnop '), 'SR-ABCD-EFGH-IJKL-MNOP');
    expect(normalizeLicenseKey('ABCDEFGHIJKLMNOP'), 'SR-ABCD-EFGH-IJKL-MNOP');
    expect(normalizeLicenseKey('SR-1234'), isNull);

    final pro = service();
    await expectLater(pro.activate('SR-AAAA-AAAA-AAAA-AAAA'), throwsA(isA<ProException>()));
    api.licences['SR-ABCD-EFGH-IJKL-MNOP'] = {
      'key': 'SR-ABCD-EFGH-IJKL-MNOP', 'active': true, 'plan': 'monthly', 'status': 'active',
      'renews': '2030-01-01T00:00:00Z', 'canManage': true,
    };
    final l = await pro.activate('sr abcd efgh ijkl mnop');
    expect(l.plan, ProPlan.monthly);
    expect(pro.isPro, isTrue);

    api.licences['SR-ENDS-ENDS-ENDS-ENDS'] = {'key': 'SR-ENDS-ENDS-ENDS-ENDS', 'active': false, 'plan': 'monthly', 'status': 'canceled'};
    await expectLater(pro.activate('SR-ENDS-ENDS-ENDS-ENDS'), throwsA(predicate((e) => '$e'.contains('ended'))));
  });

  test('offline: monthly stays Pro for 14 days after the last check, lifetime always', () async {
    var now = DateTime(2026, 11, 1);
    api.licences['SR-ABCD-EFGH-IJKL-MNOP'] = {'key': 'SR-ABCD-EFGH-IJKL-MNOP', 'active': true, 'plan': 'monthly', 'status': 'active'};
    final pro = service(clock: () => now);
    await pro.activate('SR-ABCD-EFGH-IJKL-MNOP');
    now = now.add(const Duration(days: 13));
    expect(pro.isPro, isTrue);
    now = now.add(const Duration(days: 2));
    expect(pro.isPro, isFalse);
  });
}
