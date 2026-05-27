import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../wallet/inapp_create_screen.dart';
import '../wallet/inapp_unlock_screen.dart';
import 'dapp_browser_view.dart';

/// Browse tab. Gated on an unlocked in-app wallet; otherwise prompts the user
/// to create or unlock one before the webview mounts.
class DAppBrowserScreen extends StatelessWidget {
  const DAppBrowserScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<WalletService>(
      builder: (context, wallet, _) {
        final lw = wallet.libwallet;
        if (!lw.hasWallet) {
          return _Gate(
            title: 'Set up your in-app wallet',
            subtitle:
                'The dApp browser signs transactions with your in-app MPC '
                'wallet. External wallets can\'t be used here.',
            actionLabel: 'Create wallet',
            onAction: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const InAppCreateScreen()),
            ),
          );
        }
        if (!lw.isUnlocked) {
          return _Gate(
            title: 'Unlock your wallet',
            subtitle: 'Enter your password to use the dApp browser.',
            actionLabel: 'Unlock',
            onAction: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const InAppUnlockScreen()),
            ),
          );
        }
        return const DAppBrowserView();
      },
    );
  }
}

class _Gate extends StatelessWidget {
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;

  const _Gate({
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
              const Icon(
                Icons.shield_outlined,
                size: 48,
                color: TibaneColors.orange,
              ),
              const SizedBox(height: 16),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: TibaneColors.textMuted,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: TibaneColors.orange,
                  foregroundColor: TibaneColors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
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
