import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show RemoteKeySession;
import 'package:provider/provider.dart';

import '../../services/wallet/libwallet_backend.dart' show SwitchResult;
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';

/// Preferred initial route for the unlock screen. Pure decision, extracted
/// so it can be unit-tested without a platform.
enum UnlockRoute { biometric, password, recovery }

/// Prompt for the in-app wallet password so we can sign until the app is killed.
///
/// Two modes, chosen on init based on whether the device share is
/// locally available (SecureKeystore / fallback blob):
///
/// - **Password mode** — normal path. Render the password field and
///   the biometric shortcut. Calls `unlock(password)`.
/// - **2FA recovery mode** — entered when the device share is missing
///   locally (cross-device backup import, fresh install after data
///   wipe, etc.). Asks for the password + sends an SMS/email
///   verification code, then on validate runs the auto-reshare to
///   mint a fresh device share locally. Subsequent unlocks fall back
///   to password mode.
class InAppUnlockScreen extends StatefulWidget {
  /// Wallet to unlock. Null = the active wallet (legacy callers). When set
  /// and not the active wallet, unlocking SWITCHES to it via
  /// `LibwalletBackend.switchWallet`.
  final String? walletId;

  const InAppUnlockScreen({super.key, this.walletId});

  @override
  State<InAppUnlockScreen> createState() => _InAppUnlockScreenState();

  /// Pure routing decision (biometric → password → recovery), extracted so it
  /// can be unit-tested without a platform.
  @visibleForTesting
  static UnlockRoute unlockRoute({
    required bool hasLocalShare,
    required bool biometricEnabled,
    required bool targetIsActive,
  }) {
    if (!hasLocalShare) return UnlockRoute.recovery;
    if (biometricEnabled && targetIsActive) return UnlockRoute.biometric;
    return UnlockRoute.password;
  }

  /// Make sure [walletId] (or the active wallet when null) is unlocked before
  /// a signing action. Non-inapp backends are a no-op (returns true). Tries
  /// the biometric password cache first — but only for the already-active
  /// wallet, since that cache is single-slot — else pushes the unlock screen
  /// targeting [walletId] and reports whether it ended up active + unlocked.
  static Future<bool> ensureUnlocked(
    BuildContext context, {
    String? walletId,
  }) async {
    final wallet = context.read<WalletService>();
    final backend = wallet.libwallet;
    if (walletId == null && wallet.kind != WalletKind.inapp) return true;
    final target = walletId ?? backend.walletId;
    if (backend.walletId == target && backend.isUnlocked) return true;
    if (backend.walletId == target && await backend.unlockWithBiometric()) {
      return true;
    }
    if (!context.mounted) return false;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => InAppUnlockScreen(walletId: walletId)),
    );
    if (!context.mounted) return false;
    return backend.walletId == target && backend.isUnlocked;
  }
}

enum _Mode { probing, password, recovery }

class _InAppUnlockScreenState extends State<InAppUnlockScreen> {
  final _pwCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  _Mode _mode = _Mode.probing;
  bool _busy = false;
  bool _biometricEnabled = false;
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
    final hasShare = await backend.hasLocalDeviceShare(widget.walletId);
    if (!mounted) return;
    if (!hasShare) {
      // Make the recovery flow target the requested (possibly non-active)
      // wallet by loading its metadata into the active slot first.
      if (widget.walletId != null && !targetIsActive) {
        await backend.loadWalletForRecovery(widget.walletId!);
        if (!mounted) return;
      }
      setState(() => _mode = _Mode.recovery);
      return;
    }
    final biometricEnabled = await backend.isBiometricEnabled();
    if (!mounted) return;
    final route = InAppUnlockScreen.unlockRoute(
      hasLocalShare: hasShare,
      biometricEnabled: biometricEnabled,
      targetIsActive: targetIsActive,
    );
    setState(() {
      _mode = _Mode.password;
      _biometricEnabled = route == UnlockRoute.biometric;
    });
  }

  @override
  void dispose() {
    _pwCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final wallet = context.read<WalletService>();
    final backend = wallet.libwallet;
    final target = widget.walletId;
    final bool ok;
    if (target != null && target != backend.walletId) {
      // Unlocking a different wallet means switching to it.
      ok =
          await backend.switchWallet(target, password: _pwCtrl.text) ==
          SwitchResult.ok;
    } else {
      ok = await backend.unlock(_pwCtrl.text);
    }
    if (!mounted) return;
    if (ok) {
      await wallet.useLibwallet();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = backend.error ?? 'Unlock failed';
      });
    }
  }

  Future<void> _unlockWithBiometric() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final wallet = context.read<WalletService>();
    final ok = await wallet.libwallet.unlockWithBiometric();
    if (!mounted) return;
    if (ok) {
      await wallet.useLibwallet();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = 'Biometric unlock cancelled or failed';
      });
    }
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
      appBar: AppBar(title: const Text('Unlock wallet')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_mode) {
            _Mode.probing => const Center(
              child: CircularProgressIndicator(color: TibaneColors.orange),
            ),
            _Mode.password => _buildPasswordBody(),
            _Mode.recovery => _buildRecoveryBody(),
          },
        ),
      ),
    );
  }

  Widget _buildPasswordBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Enter the password you set when creating this wallet.',
          style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _pwCtrl,
          obscureText: true,
          enabled: !_busy,
          autofocus: true,
          onSubmitted: (_) => _unlock(),
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const Spacer(),
        if (_biometricEnabled) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : _unlockWithBiometric,
            icon: const Icon(Icons.fingerprint, size: 20),
            label: const Text('Use biometric'),
            style: OutlinedButton.styleFrom(
              foregroundColor: TibaneColors.orange,
              side: const BorderSide(color: TibaneColors.orange),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 10),
        ],
        FilledButton(
          onPressed: _busy ? null : _unlock,
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(
            _busy ? 'Unlocking…' : 'Unlock',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
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
