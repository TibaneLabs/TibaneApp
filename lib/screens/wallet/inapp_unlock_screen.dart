import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show RemoteKeySession;
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/keyboard_safe_form.dart';
import '../../utils/log.dart';

/// 2FA device-share recovery screen (Atonline-parity §4.8). Signing is lockless
/// (per-transaction via the sign sheet), so there is no "unlock" — this screen
/// exists only for the case where a wallet's StoreKey (device share) isn't on
/// this device (cross-device backup import, fresh install after a data wipe).
/// It asks for the wallet password + a 2FA code, then runs the auto-reshare to
/// mint a fresh device share locally.
class InAppUnlockScreen extends StatefulWidget {
  /// Wallet to recover. Null = the active wallet. When set and not the active
  /// wallet, its metadata is loaded into the active slot so the reshare targets
  /// it (`LibwalletBackend.loadWalletForRecovery`).
  final String? walletId;

  const InAppUnlockScreen({super.key, this.walletId});

  @override
  State<InAppUnlockScreen> createState() => _InAppUnlockScreenState();
}

enum _Mode { probing, recovery }

class _InAppUnlockScreenState extends State<InAppUnlockScreen> {
  final _pwCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  _Mode _mode = _Mode.probing;
  bool _busy = false;
  String? _error;
  RemoteKeySession? _recoverySession;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final backend = context.read<WalletService>().libwallet;
    final targetIsActive =
        widget.walletId == null || widget.walletId == backend.walletId;
    // Load the target (possibly non-active) wallet's metadata into the active
    // slot first, so the 2FA reshare targets it.
    if (widget.walletId != null && !targetIsActive) {
      await backend.loadWalletForRecovery(widget.walletId!);
      if (!mounted) return;
    }
    setState(() => _mode = _Mode.recovery);
  }

  @override
  void dispose() {
    _pwCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendRecoveryCode() async {
    if (_pwCtrl.text.isEmpty) {
      setState(() => _error = 'Enter your password first');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final wallet = context.read<WalletService>();
    final session = await wallet.libwallet.startRemoteKeyReshare();
    if (!mounted) return;
    if (session == null) {
      logError('[InAppUnlock._sendRecoveryCode] send code failed: ${wallet.libwallet.error}');
      setState(() {
        _busy = false;
        _error = wallet.libwallet.error ?? 'Could not send verification code';
      });
      return;
    }
    setState(() {
      _busy = false;
      _recoverySession = session;
    });
  }

  Future<void> _verifyAndRecover() async {
    final session = _recoverySession;
    if (session == null) return;
    if (_codeCtrl.text.isEmpty) {
      setState(() => _error = 'Enter the verification code');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final wallet = context.read<WalletService>();
    final ok = await wallet.libwallet.recoverDeviceShareVia2fa(
      sessionToken: session.session,
      code: _codeCtrl.text.trim(),
      password: _pwCtrl.text,
    );
    if (!mounted) return;
    if (ok) {
      await wallet.useLibwallet();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } else {
      logError('[InAppUnlock._verifyAndRecover] 2FA recovery failed: ${wallet.libwallet.error}');
      setState(() {
        _busy = false;
        _error = wallet.libwallet.error ?? '2FA recovery failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Recover device key')),
      body: SafeArea(
        child: switch (_mode) {
          _Mode.probing => const Center(
            child: CircularProgressIndicator(color: TibaneColors.orange),
          ),
          _Mode.recovery => KeyboardSafeForm(child: _buildRecoveryBody()),
        },
      ),
    );
  }

  Widget _buildRecoveryBody() {
    final codeSent = _recoverySession != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'This wallet hasn\'t been unlocked on this device yet.',
          style: TextStyle(
            color: TibaneColors.text,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          codeSent
              ? 'Enter the verification code we just sent to your registered '
                    'email or phone. We\'ll set up the device share for this '
                    'phone — takes a few seconds after you verify.'
              : 'Verify via 2FA to set up the device share for this phone. '
                    'We\'ll send a code to your registered email or phone.',
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _pwCtrl,
          obscureText: true,
          enabled: !_busy && !codeSent,
          autofocus: !codeSent,
          decoration: const InputDecoration(labelText: 'Wallet password'),
        ),
        if (codeSent) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _codeCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            enabled: !_busy,
            autofocus: true,
            onSubmitted: (_) => _verifyAndRecover(),
            decoration: const InputDecoration(labelText: 'Verification code'),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const Spacer(),
        if (codeSent) ...[
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    setState(() {
                      _recoverySession = null;
                      _codeCtrl.clear();
                      _error = null;
                    });
                  },
            child: const Text(
              'Resend code',
              style: TextStyle(color: TibaneColors.orange),
            ),
          ),
          const SizedBox(height: 4),
        ],
        FilledButton(
          onPressed: _busy
              ? null
              : (codeSent ? _verifyAndRecover : _sendRecoveryCode),
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(
            _busy
                ? (codeSent ? 'Verifying…' : 'Sending…')
                : (codeSent ? 'Verify and unlock' : 'Send code'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
