import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';

/// Reset a wallet's password WITHOUT the old one, using 2FA. Launched from the
/// wallet detail screen. Uses the on-device StoreKey share + a 2FA-validated
/// RemoteKey to reshare a new Password (`LibwalletBackend.resetPasswordVia2fa`).
/// The wallet's address and funds are unchanged; only the password share is
/// rotated.
class ResetPasswordScreen extends StatefulWidget {
  final String walletId;
  final String? walletName;

  const ResetPasswordScreen({
    super.key,
    required this.walletId,
    this.walletName,
  });

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

enum _Phase { intro, code }

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _codeCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _pw2Ctrl = TextEditingController();

  _Phase _phase = _Phase.intro;
  String? _sessionToken;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _codeCtrl.dispose();
    _pwCtrl.dispose();
    _pw2Ctrl.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final backend = context.read<WalletService>().libwallet;
    // Load the target wallet so the RemoteKey reshare targets it.
    final loaded = await backend.loadWalletForRecovery(widget.walletId);
    if (!mounted) return;
    if (!loaded) {
      logError('[ResetPassword._sendCode] load wallet failed: ${backend.error}');
      setState(() {
        _busy = false;
        _error = WalletError.from(
          backend.error ?? 'Could not load wallet',
        ).message;
      });
      return;
    }
    final session = await backend.startRemoteKeyReshare();
    if (!mounted) return;
    if (session == null) {
      logError('[ResetPassword._sendCode] start reshare failed: ${backend.error}');
      setState(() {
        _busy = false;
        _error = WalletError.from(
          backend.error ?? 'Could not send verification code',
        ).message;
      });
      return;
    }
    setState(() {
      _busy = false;
      _sessionToken = session.session;
      _phase = _Phase.code;
    });
  }

  Future<void> _reset() async {
    final l10n = context.l10n;
    final token = _sessionToken;
    if (token == null) return;
    if (_codeCtrl.text.trim().isEmpty) {
      setState(() => _error = l10n.errEnterVerificationCode);
      return;
    }
    if (_pwCtrl.text.length < 8) {
      setState(() => _error = l10n.resetPwErrPasswordShort);
      return;
    }
    if (_pwCtrl.text != _pw2Ctrl.text) {
      setState(() => _error = l10n.errPasswordsMismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final wallet = context.read<WalletService>();
    final ok = await wallet.libwallet.resetPasswordVia2fa(
      sessionToken: token,
      code: _codeCtrl.text.trim(),
      newPassword: _pwCtrl.text,
    );
    if (!mounted) return;
    if (ok) {
      // The reset wallet is now active + unlocked; make the app use it.
      await wallet.useLibwallet();
      if (!mounted) return;
      final l10nInner = context.l10n;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10nInner.resetPwSuccess)),
      );
      Navigator.of(context).pop(true);
    } else {
      logError('[ResetPassword._reset] reset failed: ${wallet.libwallet.error}');
      setState(() {
        _busy = false;
        _error = WalletError.from(
          wallet.libwallet.error ?? 'Password reset failed',
        ).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.resetPassword)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _phase == _Phase.intro ? _introBody(l10n) : _codeBody(l10n),
          ),
        ),
      ),
    );
  }

  List<Widget> _introBody(AppLocalizations l10n) {
    final name = (widget.walletName != null && widget.walletName!.isNotEmpty)
        ? '"${widget.walletName}"'
        : l10n.commonThisWallet;
    return [
      const Icon(Icons.lock_reset, color: TibaneColors.orange, size: 48),
      const SizedBox(height: 16),
      Text(
        l10n.resetPwIntroHeading(name),
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: TibaneColors.text,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 12),
      Text(
        l10n.resetPwIntroBody,
        textAlign: TextAlign.center,
        style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: const TextStyle(color: TibaneColors.error)),
      ],
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _sendCode,
        style: FilledButton.styleFrom(
          backgroundColor: TibaneColors.orange,
          foregroundColor: TibaneColors.black,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        child: Text(
          _busy ? l10n.commonSending : l10n.actionSendVerificationCode,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    ];
  }

  List<Widget> _codeBody(AppLocalizations l10n) {
    return [
      Text(
        l10n.resetPwCodeIntro,
        textAlign: TextAlign.center,
        style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _codeCtrl,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: l10n.labelVerificationCode),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _pwCtrl,
        enabled: !_busy,
        obscureText: true,
        decoration: InputDecoration(
          labelText: l10n.resetPwNewPasswordLabel,
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _pw2Ctrl,
        enabled: !_busy,
        obscureText: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _busy ? null : _reset(),
        decoration: InputDecoration(labelText: l10n.resetPwConfirmLabel),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: const TextStyle(color: TibaneColors.error)),
      ],
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _reset,
        style: FilledButton.styleFrom(
          backgroundColor: TibaneColors.orange,
          foregroundColor: TibaneColors.black,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        child: Text(
          _busy ? l10n.resetPwResetting : l10n.resetPassword,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _busy
            ? null
            : () => setState(() {
                _phase = _Phase.intro;
                _error = null;
              }),
        child: Text(
          l10n.actionBack,
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
      ),
    ];
  }
}
