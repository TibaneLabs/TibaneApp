import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import 'inapp_create_screen.dart';
import 'wallet_dashboard.dart';

/// "Wallet" tab shown on non-Seeker devices. Read-only views (balances,
/// recent activity) render even when the wallet is locked — unlocking is
/// deferred to the moment a signing action is invoked (Send, Swap, etc.).
class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<WalletService>(
      builder: (context, wallet, _) {
        final lw = wallet.libwallet;
        if (!lw.hasWallet) {
          return _Gate(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Create your wallet',
            subtitle:
                'Set up a secure MPC wallet with email or SMS recovery. '
                'Your keys are split across this device, a 2FA share, and a password.',
            actionLabel: 'Get started',
            onAction: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const InAppCreateScreen()),
            ),
          );
        }
        return const WalletDashboard();
      },
    );
  }
}

class _Gate extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;

  const _Gate({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: TibaneColors.orange),
              const SizedBox(height: 20),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: TibaneColors.textMuted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: TibaneColors.orange,
                  foregroundColor: TibaneColors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 36,
                    vertical: 14,
                  ),
                ),
                child: Text(
                  actionLabel,
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
