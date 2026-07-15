import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../widgets/gradient_button.dart';

/// Mandatory one-time screen (Atonline-parity Phase 3 / D7) that re-secures
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
      setState(() => _error = context.l10n.bioMigPartialError);
    } catch (e) {
      logError('[BiometricMigration._secure] migrate to biometric error: $e');
      if (!mounted) return;
      setState(() => _error = WalletError.from(e).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
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
                  l10n.bioMigTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.bioMigBody,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
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
                  label: l10n.bioMigButton,
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
