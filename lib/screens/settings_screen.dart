import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/tibane_card.dart';
import 'settings/browser_screen.dart';
import 'settings/connections_screen.dart';
import 'settings/general_screen.dart';
import 'settings/help_faq_screen.dart';
import 'settings/security_privacy_screen.dart';
import 'settings/wallets_accounts_screen.dart';
import 'tools_screen.dart';

/// Top-level Settings screen. Shows the drill-down categories and the
/// lock/disconnect tile.
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
    final l10n = context.l10n;
    final wallet = context.watch<WalletService>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(l10n.settingsSection),
          const SizedBox(height: 10),
          SettingsTile(
            icon: Icons.account_balance_wallet_outlined,
            title: l10n.settingsWalletsAccountsTitle,
            subtitle: l10n.settingsWalletsAccountsSubtitle,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const WalletsAccountsScreen()),
            ),
          ),
          const SizedBox(height: 6),
          SettingsTile(
            icon: Icons.lock_outline,
            title: l10n.settingsSecurityPrivacyTitle,
            subtitle: l10n.settingsSecurityPrivacySubtitle,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SecurityPrivacyScreen()),
            ),
          ),
          const SizedBox(height: 6),
          SettingsTile(
            icon: Icons.link,
            title: l10n.settingsConnectionsTitle,
            subtitle: l10n.settingsConnectionsSubtitle,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ConnectionsScreen()),
            ),
          ),
          const SizedBox(height: 6),
          SettingsTile(
            key: const Key('settings-tools'),
            icon: Icons.handyman_outlined,
            title: l10n.homeToolsCardTitle,
            subtitle: l10n.homeToolsCardDesc,
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const ToolsScreen())),
          ),
          const SizedBox(height: 6),
          SettingsTile(
            icon: Icons.public,
            title: l10n.browserTitle,
            subtitle: l10n.settingsBrowserSubtitle,
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const BrowserScreen())),
          ),
          const SizedBox(height: 6),
          SettingsTile(
            icon: Icons.tune,
            title: l10n.settingsGeneralTitle,
            subtitle: l10n.settingsGeneralSubtitle,
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const GeneralScreen())),
          ),
          const SizedBox(height: 6),
          SettingsTile(
            icon: Icons.help_outline,
            title: l10n.helpFaqTitle,
            subtitle: l10n.settingsHelpFaqSubtitle,
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const HelpFaqScreen())),
          ),

          // In-app wallets are lockless (no persistent unlock to lock), so the
          // tile applies only to external MWA wallets — "Disconnect".
          if (wallet.isConnected && wallet.kind != WalletKind.inapp) ...[
            const SizedBox(height: 24),
            SettingsTile(
              icon: Icons.logout_outlined,
              title: l10n.actionDisconnect,
              destructive: true,
              onTap: () => _confirmDisconnect(context, wallet),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmDisconnect(
    BuildContext context,
    WalletService wallet,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(l10n.settingsDisconnectDialogTitle),
        content: Text(
          l10n.settingsDisconnectDialogBody,
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.actionDisconnect,
              style: const TextStyle(color: TibaneColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // External "Disconnect" tears down the MWA session (libwallet doesn't own
    // those keys). In-app wallets are lockless and stay on the device — there's
    // nothing to lock; switch away via the wallet switcher instead.
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
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: TextStyle(color: color, fontSize: 17.25)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: monoStyle(
                      fontSize: 12.65,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right,
            color: TibaneColors.textDim,
            size: 21.6,
          ),
        ],
      ),
    );
  }
}
