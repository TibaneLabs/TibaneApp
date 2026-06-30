import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../screens/wallet/inapp_create_screen.dart';
import '../screens/wallet/inapp_unlock_screen.dart';
import '../screens/wallet/widgets/account_switcher_sheet.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';

/// Wallet connect/disconnect button for the app bar
class WalletButton extends StatelessWidget {
  const WalletButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<WalletService>(
      builder: (context, wallet, _) {
        if (wallet.isConnecting) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: TibaneColors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: TibaneColors.border),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: TibaneColors.orange,
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  'Connecting...',
                  style: TextStyle(color: TibaneColors.textMuted, fontSize: 13),
                ),
              ],
            ),
          );
        }

        if (wallet.isConnected) {
          return _ConnectedButton(wallet: wallet);
        }

        return _ConnectButton(wallet: wallet);
      },
    );
  }
}

class _ConnectButton extends StatelessWidget {
  final WalletService wallet;

  const _ConnectButton({required this.wallet});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TibaneColors.orange,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: () => _showConnectDialog(context),
        borderRadius: BorderRadius.circular(8),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 16,
                color: TibaneColors.black,
              ),
              SizedBox(width: 6),
              Text(
                'Connect',
                style: TextStyle(
                  color: TibaneColors.black,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openInAppFlow(BuildContext context, WalletService wallet) {
    final screen = wallet.libwallet.hasWallet
        ? const InAppUnlockScreen()
        : const InAppCreateScreen();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// Connect an external MWA/Seed Vault wallet and surface a clear error when
  /// it fails — most importantly when no compatible wallet app is installed
  /// (native `NO_WALLET`). Captures the messenger before the sheet closes.
  Future<void> _connectExternal(BuildContext sheetContext) async {
    final messenger = ScaffoldMessenger.of(sheetContext);
    Navigator.pop(sheetContext);
    final ok = await wallet.connectMwa();
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            wallet.mwa.error ?? 'No compatible wallet app is installed.',
          ),
        ),
      );
    }
  }

  void _showConnectDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: TibaneColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: TibaneColors.textDim,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Connect Wallet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Connect your Solana wallet to use Tibane tools',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: TibaneColors.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (Platform.isAndroid) ...[
              _WalletOption(
                name: 'Seed Vault',
                subtitle: 'Seeker native wallet',
                icon: Icons.security,
                onTap: () => _connectExternal(context),
              ),
              const SizedBox(height: 12),
              _WalletOption(
                name: 'Other Wallet',
                subtitle: 'Phantom, Solflare, etc.',
                icon: Icons.wallet,
                onTap: () => _connectExternal(context),
              ),
              const SizedBox(height: 12),
            ],
            _WalletOption(
              name: 'In-app wallet',
              subtitle: wallet.libwallet.hasWallet
                  ? 'Unlock your Tibane wallet'
                  : 'Create a new MPC wallet',
              icon: Icons.shield_outlined,
              onTap: () {
                Navigator.pop(context);
                _openInAppFlow(context, wallet);
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _WalletOption extends StatelessWidget {
  final String name;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _WalletOption({
    required this.name,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TibaneColors.darker,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: TibaneColors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: TibaneColors.orange, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: TibaneColors.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: TibaneColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: TibaneColors.textDim),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectedButton extends StatelessWidget {
  final WalletService wallet;

  const _ConnectedButton({required this.wallet});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TibaneColors.card,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: () => showAccountSwitcher(context),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: TibaneColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Green dot
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: TibaneColors.cyan,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              if (wallet.chiefPussyBalance > BigInt.zero) ...[
                Text(
                  formatTokenAmount(
                    wallet.chiefPussyBalance,
                    6,
                    displayDecimals: 0,
                  ),
                  style: monoStyle(fontSize: 12, color: TibaneColors.gold),
                ),
                const SizedBox(width: 6),
                const Text(
                  '|',
                  style: TextStyle(color: TibaneColors.textDim, fontSize: 12),
                ),
                const SizedBox(width: 6),
              ],
              Text(wallet.shortAddress, style: monoStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

}
