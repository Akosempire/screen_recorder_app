import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/pro_service.dart';
import '../ui/studio_theme.dart';
import '../ui/studio_widgets.dart';

/// Opens the Upgrade / Pro window. [reason] explains why it opened (e.g. the
/// free limit was reached).
Future<void> showUpgradeDialog(BuildContext context, {String? reason}) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x33000000),
    builder: (_) => UpgradeDialog(reason: reason),
  );
}

/// Naira for people in Nigeria, dollars elsewhere (they can switch).
ProCurrency defaultProCurrency() {
  final locale = Platform.localeName.toUpperCase();
  final tz = DateTime.now().timeZoneName.toUpperCase();
  return locale.endsWith('_NG') || locale.contains('-NG') || tz == 'WAT' || tz.contains('LAGOS')
      ? ProCurrency.ngn
      : ProCurrency.usd;
}

class UpgradeDialog extends StatefulWidget {
  const UpgradeDialog({super.key, this.reason, this.service});

  final String? reason;
  final ProService? service;

  @override
  State<UpgradeDialog> createState() => _UpgradeDialogState();
}

class _UpgradeDialogState extends State<UpgradeDialog> {
  ProService get _pro => widget.service ?? ProService.instance;

  ProPlan _plan = ProPlan.lifetime;
  ProCurrency _currency = defaultProCurrency();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _key = TextEditingController();
  bool _showKey = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ProException catch (error) {
      _error = error.message;
    } catch (error) {
      _error = 'Something went wrong. Try again in a minute.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _buy() {
    final name = _name.text.trim();
    final email = _email.text.trim();
    if (name.isEmpty) return setState(() => _error = 'Enter your name.');
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(email)) {
      return setState(() => _error = 'Enter a valid email address, like you@example.com.');
    }
    _run(() => _pro.buy(plan: _plan, currency: _currency, email: email, name: name));
  }

  void _activate() => _run(() async {
        await _pro.activate(_key.text);
      });

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Studio.theme(Theme.of(context)),
      child: Dialog(
        backgroundColor: Studio.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Studio.radiusLg)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListenableBuilder(
            listenable: _pro,
            builder: (context, _) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
              child: _pro.isPro
                  ? _proView()
                  : _pro.waitingForPayment
                      ? _waitingView()
                      : _buyView(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(String title, {String? subtitle}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: StudioText.title.copyWith(fontSize: 20)),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle, style: StudioText.caption.copyWith(fontSize: 13, height: 1.4)),
              ],
            ],
          ),
        ),
        IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, size: 20),
        ),
      ],
    );
  }

  Widget _errorText() => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(_error!, style: StudioText.caption.copyWith(color: Studio.danger, fontSize: 13)),
        );

  // ---- buy -------------------------------------------------------------------

  Widget _buyView() {
    final limit = _pro.freeLimit.inMinutes;
    final reason = widget.reason ?? (_pro.stoppedAtLimit
        ? 'Your recording stopped at $limit minutes, the trial limit, and it has been kept. Go Pro to record as long as you like.'
        : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header('Go Pro', subtitle: 'Try every feature on recordings up to $limit minutes. Pro removes the limit.'),
        if (reason != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF6DB),
              borderRadius: BorderRadius.circular(Studio.radius),
              border: Border.all(color: const Color(0xFFF5DC8A)),
            ),
            child: Text(reason, style: StudioText.body.copyWith(height: 1.4)),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            const Text('Pay in', style: StudioText.label),
            const SizedBox(width: 10),
            StudioSegmented<ProCurrency>(
              dense: true,
              value: _currency,
              onChanged: _busy ? null : (c) => setState(() => _currency = c),
              segments: const [
                StudioSegment(ProCurrency.ngn, '₦ Naira'),
                StudioSegment(ProCurrency.usd, r'$ Dollars'),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _planCard(ProPlan.monthly, 'Monthly', '/ month', 'Cancel any time')),
            const SizedBox(width: 10),
            Expanded(child: _planCard(ProPlan.lifetime, 'Lifetime', 'once', 'Best value · pay once')),
          ],
        ),
        const SizedBox(height: 14),
        if (!_pro.paymentsEnabled) ...[
          Text('Buying Pro opens soon. You can already unlock it with a licence key.',
              style: StudioText.caption.copyWith(fontSize: 13)),
        ] else ...[
          _field(_name, 'Your name', autofill: AutofillHints.name),
          const SizedBox(height: 8),
          _field(_email, 'Email (for your receipt and licence)', autofill: AutofillHints.email, email: true),
          const SizedBox(height: 14),
          StudioPrimaryButton(
            large: true,
            busy: _busy,
            label: 'Continue to payment · ${proPrice(_plan, _currency)}',
            onPressed: _buy,
          ),
          const SizedBox(height: 6),
          Text('Opens Bachs secure checkout in your browser: cards, bank transfer and more. '
              'Screen Recorder unlocks by itself once you have paid.',
              style: StudioText.tiny.copyWith(height: 1.4)),
        ],
        _errorText(),
        const SizedBox(height: 10),
        const Divider(height: 20),
        if (!_showKey)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _showKey = true),
              child: const Text('I have a licence key'),
            ),
          )
        else
          Row(
            children: [
              Expanded(child: _field(_key, 'SR-XXXX-XXXX-XXXX-XXXX', onSubmit: _activate)),
              const SizedBox(width: 8),
              StudioPrimaryButton(label: 'Activate', busy: _busy, onPressed: _activate),
            ],
          ),
      ],
    );
  }

  Widget _planCard(ProPlan plan, String title, String per, String note) {
    final selected = _plan == plan;
    return Material(
      color: selected ? const Color(0xFF111114) : Studio.chrome,
      borderRadius: BorderRadius.circular(Studio.radiusLg),
      child: InkWell(
        borderRadius: BorderRadius.circular(Studio.radiusLg),
        onTap: _busy ? null : () => setState(() => _plan = plan),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: selected ? Colors.white : Studio.ink)),
                  const Spacer(),
                  Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                      size: 18, color: selected ? Studio.highlight : Studio.faint),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(proPrice(plan, _currency),
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          color: selected ? Colors.white : Studio.ink)),
                  const SizedBox(width: 6),
                  Text(per, style: TextStyle(fontSize: 12, color: selected ? const Color(0xFFB4B4BA) : Studio.muted)),
                ],
              ),
              const SizedBox(height: 4),
              Text(note, style: TextStyle(fontSize: 12, color: selected ? const Color(0xFFD4D4D8) : Studio.muted)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint,
      {String? autofill, bool email = false, VoidCallback? onSubmit}) {
    return TextField(
      controller: c,
      enabled: !_busy,
      keyboardType: email ? TextInputType.emailAddress : TextInputType.text,
      autofillHints: autofill == null ? null : [autofill],
      onSubmitted: onSubmit == null ? null : (_) => onSubmit(),
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: Studio.chrome,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(Studio.radius), borderSide: BorderSide.none),
      ),
    );
  }

  // ---- waiting ---------------------------------------------------------------

  Widget _waitingView() {
    final plan = _pro.pendingPlan == ProPlan.monthly ? 'Pro Monthly' : 'Pro Lifetime';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header('Finish paying in your browser', subtitle: '$plan · Bachs secure checkout'),
        const SizedBox(height: 22),
        const Center(child: SizedBox(width: 30, height: 30, child: CircularProgressIndicator(strokeWidth: 3))),
        const SizedBox(height: 16),
        const Text(
          'Screen Recorder unlocks by itself as soon as your payment is confirmed. '
          'You can leave this window open or close it; it keeps checking.',
          textAlign: TextAlign.center,
          style: StudioText.body,
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: StudioSecondaryButton(
                label: 'Cancel purchase',
                onPressed: () => _pro.cancelPurchase(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: StudioSecondaryButton(
                label: 'Use a licence key',
                onPressed: () async {
                  await _pro.cancelPurchase();
                  setState(() => _showKey = true);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---- already Pro -----------------------------------------------------------

  Widget _proView() {
    final l = _pro.license!;
    final date = l.endsAt ?? l.renews;
    final dateText = date == null
        ? null
        : '${l.endsAt != null ? 'Ends' : 'Renews'} on ${date.day} ${_month(date.month)} ${date.year}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header("You're Pro",
            subtitle: l.plan == ProPlan.lifetime
                ? 'Lifetime access: unlimited recording length, forever.'
                : 'Pro Monthly: unlimited recording length.'),
        const SizedBox(height: 16),
        const Text('Licence key', style: StudioText.label),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: Studio.chrome, borderRadius: BorderRadius.circular(Studio.radius)),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(l.key,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () => Clipboard.setData(ClipboardData(text: l.key)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          [if (l.email != null) 'Bought with ${l.email}', if (dateText != null) dateText].join(' · '),
          style: StudioText.caption,
        ),
        _errorText(),
        const SizedBox(height: 16),
        Row(
          children: [
            if (l.canManage) ...[
              Expanded(
                child: StudioSecondaryButton(
                  label: 'Manage subscription',
                  onPressed: _busy ? null : () => _run(_pro.manageSubscription),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: StudioSecondaryButton(
                label: 'Remove from this computer',
                onPressed: _busy ? null : () => _run(_pro.signOut),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _month(int m) =>
      const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][m - 1];
}
