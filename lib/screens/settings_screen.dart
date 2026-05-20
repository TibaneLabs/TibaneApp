import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/tibane_card.dart';
import 'settings/connections_screen.dart';
import 'settings/general_screen.dart';
import 'settings/security_privacy_screen.dart';
import 'settings/wallets_accounts_screen.dart';
import 'wallet/wallet_details_screen.dart';

/// Top-level Settings screen. Shows the active-wallet card, four
/// drill-down categories (Wallets & Accounts / Security & Privacy /
/// Connections / General), and the lock/disconnect tile.
///
/// Each category screen lives in `lib/screens/settings/` and owns its
/// own Scaffold + AppBar; this screen just routes into them.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel('Active account'),
          const SizedBox(height: 10),
          _ActiveWalletCard(wallet: wallet),
          const SizedBox(height: 24),

          _SectionLabel('Settings'),
          const SizedBox(height: 10),
          SettingsTile(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Wallets & Accounts',
            subtitle: 'Accounts, networks, tokens, NFTs, contacts',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const WalletsAccountsScreen(),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SettingsTile(
            icon: Icons.lock_outline,
            title: 'Security & Privacy',
            subtitle: 'Password, biometrics, TSS shares, backups',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const SecurityPrivacyScreen(),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SettingsTile(
            icon: Icons.link,
            title: 'Connections',
            subtitle: 'WalletConnect, connected sites, agents',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ConnectionsScreen()),
            ),
          ),
          const SizedBox(height: 6),
          SettingsTile(
            icon: Icons.tune,
            title: 'General',
            subtitle: 'Region, about',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const GeneralScreen()),
            ),
          ),

          if (wallet.isConnected) ...[
            const SizedBox(height: 24),
            SettingsTile(
              icon: Icons.logout_outlined,
              title: wallet.kind == WalletKind.inapp
                  ? 'Lock wallet'
                  : 'Disconnect',
              destructive: true,
              onTap: () => _confirmDisconnect(context, wallet),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmDisconnect(
      BuildContext context, WalletService wallet) async {
    final inapp = wallet.kind == WalletKind.inapp;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(inapp ? 'Lock wallet?' : 'Disconnect wallet?'),
        content: Text(
          inapp
              ? 'You will need to re-enter your password to unlock the wallet again.'
              : 'You can reconnect by tapping the wallet button at the top.',
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              inapp ? 'Lock' : 'Disconnect',
              style: const TextStyle(color: TibaneColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await wallet.disconnect();
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
    );
  }
}

class _ActiveWalletCard extends StatelessWidget {
  final WalletService wallet;
  const _ActiveWalletCard({required this.wallet});

  @override
  Widget build(BuildContext context) {
    if (!wallet.isConnected) {
      return TibaneCard(
        child: Row(
          children: [
            const Icon(Icons.lock_outline, color: TibaneColors.textMuted),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'No wallet connected',
                style: TextStyle(color: TibaneColors.textMuted),
              ),
            ),
          ],
        ),
      );
    }

    final kindLabel = wallet.kind == WalletKind.inapp ? 'In-app' : 'External';
    final address = wallet.publicKey ?? '';
    final shortAddress = address.length > 14
        ? '${address.substring(0, 6)}...${address.substring(address.length - 6)}'
        : address;

    return TibaneCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const WalletDetailsScreen()),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: TibaneColors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  wallet.kind == WalletKind.inapp
                      ? Icons.shield_outlined
                      : Icons.account_balance_wallet_outlined,
                  color: TibaneColors.orange,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      wallet.walletName ?? 'Wallet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      kindLabel,
                      style:
                          monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'SOLANA ADDRESS',
            style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  shortAddress,
                  style: monoStyle(fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: address));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Address copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Reusable row used by the top-level Settings screen and every
/// sub-screen under `lib/screens/settings/`. Public so the sub-screens
/// can import it from one place instead of duplicating the styling.
class SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool destructive;

  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? TibaneColors.error : TibaneColors.text;
    return TibaneCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: TextStyle(color: color, fontSize: 15)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: monoStyle(
                        fontSize: 11, color: TibaneColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right,
              color: TibaneColors.textDim, size: 18),
        ],
      ),
    );
  }
}
