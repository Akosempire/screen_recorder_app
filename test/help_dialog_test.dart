import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_app/services/app_logger.dart';
import 'package:screen_recorder_app/services/support_service.dart';
import 'package:screen_recorder_app/widgets/help_dialog.dart';

void main() {
  testWidgets('Get help sends the message and says thanks', (tester) async {
    final sent = <Map<String, Object?>>[];
    Future<void> fakeSend({
      required HelpKind kind,
      required String message,
      String? email,
      bool includeDetails = true,
      String apiBase = '',
    }) async {
      sent.add({'kind': kind, 'message': message, 'email': email, 'details': includeDetails});
    }

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: HelpDialog(send: fakeSend))));
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(find.text('Tell us a little more about what happened.'), findsOneWidget);
    expect(sent, isEmpty);

    await tester.tap(find.text('Question'));
    await tester.enterText(find.byKey(const ValueKey('help-message')), 'How do I record only one window?');
    await tester.enterText(find.byKey(const ValueKey('help-email')), 'ada@example.com');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(sent.single['kind'], HelpKind.question);
    expect(sent.single['email'], 'ada@example.com');
    expect(sent.single['details'], isTrue);
    expect(find.text('Thanks, we got it'), findsOneWidget);
    expect(find.textContaining('reply to ada@example.com'), findsOneWidget);
  });

  testWidgets('a failed send shows why and keeps the message', (tester) async {
    Future<void> failing({
      required HelpKind kind,
      required String message,
      String? email,
      bool includeDetails = true,
      String apiBase = '',
    }) async =>
        throw HelpException('You seem to be offline. Connect to the internet and try again.');

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: HelpDialog(send: failing))));
    await tester.enterText(find.byKey(const ValueKey('help-message')), 'Export never finishes');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(find.textContaining('offline'), findsOneWidget);
    expect(find.text('Export never finishes'), findsOneWidget);
  });

  test('details include the recent log, without licence keys', () {
    AppLogger.info('Activated SR-ABCD-EFGH-IJKL');
    final details = helpDetails();
    expect(details, contains('Recent log:'));
    expect(details, contains('Activated SR-…'));
    expect(details, isNot(contains('ABCD-EFGH')));
  });
}
