import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show RemoteKeySession;
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/keyboard_safe_form.dart';
import '../../widgets/tibane_card.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';

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
  String? _notice; // e.g. "2FA key repaired — now verify to set up this device"
  RemoteKeySession? _recoverySession;

  /// When true the 2FA flow repairs the desynced server-side RemoteKey share
  /// from the backup copy (libwallet 0.4.76) instead of recovering the device
  /// key. Used when a restored wallet's recovery stalls ("participant stopped
  /// responding"). Repair uses its OWN fresh 2FA session; recovery then runs
  /// with another.
  bool _repairMode = false;

  /// True while showing the two-option chooser (Set up device / Repair 2FA);
  /// false once the user picks one and is in that sub-flow.
  bool _choosing = true;

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
    // Repair doesn't need the password (it pushes the backup share copy);
    // recovery does (it re-encrypts the fresh device key under it).
    if (!_repairMode && _pwCtrl.text.isEmpty) {
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
        _error = WalletError.from(
          wallet.libwallet.error ?? 'Could not send verification code',
        ).message;
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
        _error = WalletError.from(
          wallet.libwallet.error ?? '2FA recovery failed',
        ).message;
      });
    }
  }

  Future<void> _verifyAndRepair() async {
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
    final ok = await wallet.libwallet.repairRemoteKeyVia2fa(
      sessionToken: session.session,
      code: _codeCtrl.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      // Repaired. Recovery needs ANOTHER fresh session, so land in the
      // device-setup sub-flow with a note prompting the user to verify again.
      setState(() {
        _busy = false;
        _repairMode = false;
        _choosing = false;
        _recoverySession = null;
        _codeCtrl.clear();
        _error = null;
        _notice = '2FA key repaired. Now verify again to set up this device.';
      });
    } else {
      logError('[InAppUnlock._verifyAndRepair] repair failed: ${wallet.libwallet.error}');
      setState(() {
        _busy = false;
        _error = WalletError.from(
          wallet.libwallet.error ?? 'Repair failed',
        ).message;
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

  Widget _buildRecoveryBody() => _choosing ? _buildChooser() : _buildFlow();

  /// Two visually distinct options so neither path is hidden: set up the device
  /// key (normal), or repair the 2FA key first (restored-from-backup + stuck).
  Widget _buildChooser() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Recover this wallet on this device',
            style: TextStyle(
              color: TibaneColors.text,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Both options verify with a 2FA code sent to your registered email '
            'or phone.',
            style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
          ),
          if (_notice != null) ...[
            const SizedBox(height: 12),
            Text(_notice!, style: const TextStyle(color: TibaneColors.cyan)),
          ],
          const SizedBox(height: 20),
          _OptionCard(
            icon: Icons.phonelink_lock_outlined,
            title: 'Set up this device',
            body: "First time using this wallet on this phone? Verify via 2FA "
                "to create this device's signing key.",
            onTap: _busy
                ? null
                : () => setState(() {
                      _choosing = false;
                      _repairMode = false;
                      _error = null;
                    }),
          ),
          const SizedBox(height: 12),
          _OptionCard(
            icon: Icons.healing_outlined,
            title: 'Repair 2FA key',
            body: 'Restored from a backup and setup gets stuck ("participant '
                'stopped responding")? Your 2FA key may be out of sync — repair '
                'it from your backup first, then set up this device.',
            onTap: _busy
                ? null
                : () => setState(() {
                      _choosing = false;
                      _repairMode = true;
                      _error = null;
                    }),
          ),
        ],
      ),
    );
  }

  /// The 2FA flow for the chosen option (send code → enter code → submit).
  Widget _buildFlow() {
    final codeSent = _recoverySession != null;
    final repair = _repairMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!codeSent)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _choosing = true;
                        _recoverySession = null;
                        _codeCtrl.clear();
                        _error = null;
                      }),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Back'),
              style: TextButton.styleFrom(
                foregroundColor: TibaneColors.textMuted,
              ),
            ),
          ),
        Text(
          repair ? "Repair this wallet's 2FA key" : 'Set up this device',
          style: const TextStyle(
            color: TibaneColors.text,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          repair
              ? (codeSent
                  ? 'Enter the code we just sent. This re-syncs your 2FA key '
                        'from your backup so setup can complete.'
                  : "We'll send a 2FA code to repair your 2FA key from your "
                        'backup. No password needed for this step.')
              : (codeSent
                  ? 'Enter the verification code we just sent to your registered '
                        'email or phone — takes a few seconds after you verify.'
                  : "Verify via 2FA to create this device's signing key. We'll "
                        'send a code to your registered email or phone.'),
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        // Single-device wallet: the committee has one device-key slot, so
        // "Set up this device" MOVES it here and retires any other phone set up
        // for this wallet. Warn only on the set-up path (repair doesn't touch
        // the device slot).
        if (!repair) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Icon(Icons.info_outline, color: TibaneColors.amber, size: 16),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'A wallet signs on one device at a time. Setting up here makes '
                  'this your signing device — if it was set up on another phone, '
                  'that phone will need to set up again to sign.',
                  style: TextStyle(
                    color: TibaneColors.amber,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_notice != null) ...[
          const SizedBox(height: 12),
          Text(_notice!, style: const TextStyle(color: TibaneColors.cyan)),
        ],
        const SizedBox(height: 24),
        // Password is only needed to set up the device key; repair pushes the
        // backup copy and needs no password.
        if (!repair)
          TextField(
            controller: _pwCtrl,
            obscureText: true,
            enabled: !_busy && !codeSent,
            autofocus: !codeSent,
            decoration: const InputDecoration(labelText: 'Wallet password'),
          ),
        if (codeSent) ...[
          if (!repair) const SizedBox(height: 12),
          TextField(
            controller: _codeCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            enabled: !_busy,
            autofocus: true,
            onSubmitted: (_) =>
                repair ? _verifyAndRepair() : _verifyAndRecover(),
            decoration: const InputDecoration(labelText: 'Verification code'),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        // Minimum gap that survives the Spacer collapsing when the keyboard
        // shrinks the viewport (KeyboardSafeForm switches to intrinsic height +
        // scroll, giving the Spacer zero flex). Without it the button sits flush
        // against the input/error above.
        const SizedBox(height: 24),
        const Spacer(),
        if (codeSent)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _recoverySession = null;
                      _codeCtrl.clear();
                      _error = null;
                    }),
            child: const Text(
              'Resend code',
              style: TextStyle(color: TibaneColors.orange),
            ),
          ),
        FilledButton(
          onPressed: _busy
              ? null
              : (codeSent
                  ? (repair ? _verifyAndRepair : _verifyAndRecover)
                  : _sendRecoveryCode),
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(
            _busy
                ? (codeSent
                    ? (repair ? 'Repairing…' : 'Verifying…')
                    : 'Sending…')
                : (codeSent
                    ? (repair ? 'Repair 2FA key' : 'Verify and set up')
                    : 'Send code'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// A tappable option card for the recovery chooser — icon + title + description
/// + chevron, so each path (set up / repair) is an obvious, distinct choice.
class _OptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback? onTap;

  const _OptionCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TibaneCard(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: TibaneColors.orange, size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    color: TibaneColors.textMuted,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 8, top: 2),
            child: Icon(Icons.chevron_right,
                color: TibaneColors.textDim, size: 20),
          ),
        ],
      ),
    );
  }
}
