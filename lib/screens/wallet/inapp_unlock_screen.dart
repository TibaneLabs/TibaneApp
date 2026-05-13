import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';

/// Prompt for the in-app wallet password so we can sign until the app is killed.
class InAppUnlockScreen extends StatefulWidget {
  const InAppUnlockScreen({super.key});

  @override
  State<InAppUnlockScreen> createState() => _InAppUnlockScreenState();

  /// Make sure the in-app wallet is unlocked before a signing action.
  /// For non-inapp backends (MWA, etc.) this is a no-op and returns true.
  /// For an inapp wallet that's locked, this tries the biometric password
  /// cache first; if that isn't enabled or the user cancels FaceID, the
  /// password screen is pushed and the result is whatever the user does
  /// from there.
  static Future<bool> ensureUnlocked(BuildContext context) async {
    final wallet = context.read<WalletService>();
    if (wallet.kind != WalletKind.inapp) return true;
    if (wallet.libwallet.isUnlocked) return true;
    if (await wallet.libwallet.unlockWithBiometric()) {
      // Provider's notifyListeners on unlock has already propagated; nothing
      // else to do here.
      return true;
    }
    if (!context.mounted) return false;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const InAppUnlockScreen()),
    );
    if (!context.mounted) return false;
    return wallet.libwallet.isUnlocked;
  }
}

class _InAppUnlockScreenState extends State<InAppUnlockScreen> {
  final _pwCtrl = TextEditingController();
  bool _busy = false;
  bool _biometricEnabled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initBiometricFlag();
  }

  Future<void> _initBiometricFlag() async {
    final wallet = context.read<WalletService>();
    final enabled = await wallet.libwallet.isBiometricEnabled();
    if (!mounted) return;
    setState(() => _biometricEnabled = enabled);
  }

  @override
  void dispose() {
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final wallet = context.read<WalletService>();
    final ok = await wallet.libwallet.unlock(_pwCtrl.text);
    if (!mounted) return;
    if (ok) {
      await wallet.useLibwallet();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = wallet.libwallet.error ?? 'Unlock failed';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Unlock wallet')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
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
          ),
        ),
      ),
    );
  }
}
