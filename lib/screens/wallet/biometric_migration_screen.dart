import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/gradient_button.dart';

/// Mandatory one-time screen (Ellipx-parity Phase 3 / D7) that re-secures
/// existing wallets' StoreKey behind biometric. Shown by `TibaneShell` before
/// the home whenever [LibwalletBackend.needsBiometricMigration] is true.
///
/// No defer: the user must complete it. This is safe — the migration is
/// verify-before-delete and keeps the password blob (D8), so a cancelled or
/// failed run loses nothing and simply retries.
class BiometricMigrationScreen extends StatefulWidget {
  const BiometricMigrationScreen({super.key, required this.onDone});

  /// Called once the migration completes successfully.
  final VoidCallback onDone;

  @override
  State<BiometricMigrationScreen> createState() =>
      _BiometricMigrationScreenState();
}

class _BiometricMigrationScreenState extends State<BiometricMigrationScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _secure() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok =
          await context.read<WalletService>().libwallet.migrateToBiometricV1();
      if (!mounted) return;
      if (ok) {
        widget.onDone();
        return;
      }
      setState(() => _error =
          'Some keys could not be secured. Authenticate when prompted and try '
          'again.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not secure your wallet: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // mandatory — no back-out
      child: Scaffold(
        backgroundColor: TibaneColors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                const Icon(
                  Icons.fingerprint,
                  size: 64,
                  color: TibaneColors.gold,
                ),
                const SizedBox(height: 24),
                Text(
                  'Secure your wallet',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text(
                  "We're upgrading your wallet's security: each wallet's "
                  "signing key moves behind this device's biometrics. Every "
                  'wallet is secured separately, so you will see a biometric '
                  "prompt for each wallet you have — that's expected. Your "
                  'password still works as a backup.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: TibaneColors.error,
                      fontSize: 13,
                    ),
                  ),
                ],
                const Spacer(),
                GradientButton(
                  label: 'Secure now',
                  loading: _busy,
                  expanded: true,
                  onPressed: _busy ? null : _secure,
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
