import 'package:flutter/material.dart';

import '../services/pro_service.dart';
import '../services/support_service.dart';
import '../ui/studio_theme.dart';

/// "Get help": tell us about a problem, ask a question or suggest an idea,
/// without leaving the app.
Future<void> showHelpDialog(BuildContext context) => showDialog<void>(
      context: context,
      barrierColor: const Color(0x33000000),
      builder: (_) => const HelpDialog(),
    );

class HelpDialog extends StatefulWidget {
  const HelpDialog({super.key, this.send = sendHelpRequest});

  /// Sends the request (replaced in tests).
  final Future<void> Function({
    required HelpKind kind,
    required String message,
    String? email,
    bool includeDetails,
    String apiBase,
  }) send;

  @override
  State<HelpDialog> createState() => _HelpDialogState();
}

class _HelpDialogState extends State<HelpDialog> {
  final _message = TextEditingController();
  late final _email = TextEditingController(text: ProService.instance.license?.email ?? '');
  HelpKind _kind = HelpKind.problem;
  bool _details = true;
  bool _sending = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _message.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final message = _message.text.trim();
    final email = _email.text.trim();
    if (message.length < 5) {
      setState(() => _error = 'Tell us a little more about what happened.');
      return;
    }
    if (email.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'That email doesn’t look right. Leave it empty, or use one like you@example.com.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.send(kind: _kind, message: message, email: email, includeDetails: _details);
      if (mounted) setState(() => _sent = true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Studio.theme(Theme.of(context)),
      child: AlertDialog(
        backgroundColor: Studio.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Studio.radiusLg)),
        title: Text(_sent ? 'Thanks, we got it' : 'Get help', style: StudioText.title),
        content: SizedBox(width: 440, child: _sent ? _thanks() : _form()),
        actions: _sent
            ? [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))]
            : [
                TextButton(
                  onPressed: _sending ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: _sending ? null : _submit,
                  child: Text(_sending ? 'Sending…' : 'Send'),
                ),
              ],
      ),
    );
  }

  Widget _thanks() {
    final email = _email.text.trim();
    return Text(
      email.isEmpty
          ? 'Your message reached the Screen Recorder team. You didn’t leave an email, so we can’t reply, '
              'but we read every message and use it to fix things.'
          : 'Your message reached the Screen Recorder team. We’ll reply to $email, usually within a day or two.',
      style: StudioText.body,
    );
  }

  Widget _form() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Something not working, a question, or an idea? Tell us here and it goes straight to the team.',
            style: StudioText.caption,
          ),
          const SizedBox(height: 14),
          SegmentedButton<HelpKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: HelpKind.problem, label: Text('Problem'), icon: Icon(Icons.error_outline, size: 16)),
              ButtonSegment(value: HelpKind.question, label: Text('Question'), icon: Icon(Icons.help_outline, size: 16)),
              ButtonSegment(value: HelpKind.idea, label: Text('Idea'), icon: Icon(Icons.lightbulb_outline, size: 16)),
            ],
            selected: {_kind},
            onSelectionChanged: _sending ? null : (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('help-message'),
            controller: _message,
            enabled: !_sending,
            minLines: 4,
            maxLines: 8,
            maxLength: 5000,
            autofocus: true,
            decoration: InputDecoration(
              labelText: switch (_kind) {
                HelpKind.problem => 'What happened?',
                HelpKind.question => 'Your question',
                HelpKind.idea => 'Your idea',
              },
              hintText: _kind == HelpKind.problem
                  ? 'What you were doing, what you expected, and what happened instead.'
                  : null,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('help-email'),
            controller: _email,
            enabled: !_sending,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Your email (so we can reply)',
              helperText: 'Optional. Only used to answer you.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          CheckboxListTile(
            value: _details,
            onChanged: _sending ? null : (v) => setState(() => _details = v ?? true),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: const Text('Include app details and recent log', style: StudioText.body),
            subtitle: const Text(
              'Version, system, free space and what the app did recently. Helps us find problems fast. '
              'Never your recordings.',
              style: StudioText.caption,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!, style: StudioText.caption.copyWith(color: Studio.danger)),
          ],
        ],
      ),
    );
  }
}
