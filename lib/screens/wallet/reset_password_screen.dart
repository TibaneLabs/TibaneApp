import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    final token = _sessionToken;
    if (token == null) return;
    if (_codeCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Enter the verification code');
      return;
    }
    if (_pwCtrl.text.length < 8) {
      setState(() => _error = 'New password must be at least 8 characters');
      return;
    }
    if (_pwCtrl.text != _pw2Ctrl.text) {
      setState(() => _error = 'Passwords do not match');
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password reset — wallet unlocked')),
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
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Reset password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _phase == _Phase.intro ? _introBody() : _codeBody(),
          ),
        ),
      ),
    );
  }

  List<Widget> _introBody() {
    final name = (widget.walletName != null && widget.walletName!.isNotEmpty)
        ? '“${widget.walletName}”'
        : 'this wallet';
    return [
      const Icon(Icons.lock_reset, color: TibaneColors.orange, size: 48),
      const SizedBox(height: 16),
      Text(
        'Reset the password for $name',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: TibaneColors.text,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        "Forgot your password? Set a new one with 2FA — no old password "
        "needed. We'll send a verification code to the phone or email on this "
        'wallet. This re-keys the wallet using your device key + 2FA; your '
        'address and funds are unchanged.',
        textAlign: TextAlign.center,
        style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
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
          _busy ? 'Sending…' : 'Send verification code',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    ];
  }

  List<Widget> _codeBody() {
    return [
      const Text(
        'Enter the code we sent, then choose a new password.',
        textAlign: TextAlign.center,
        style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _codeCtrl,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Verification code'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _pwCtrl,
        enabled: !_busy,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'New password (min 8 characters)',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _pw2Ctrl,
        enabled: !_busy,
        obscureText: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _busy ? null : _reset(),
        decoration: const InputDecoration(labelText: 'Confirm new password'),
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
          _busy ? 'Resetting…' : 'Reset password',
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
        child: const Text('Back', style: TextStyle(color: TibaneColors.textMuted)),
      ),
    ];
  }
}
