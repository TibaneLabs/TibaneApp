import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/tibane_theme.dart';
import 'inapp_backup_restore_screen.dart';
import 'inapp_import_mnemonic_screen.dart';
import 'inapp_import_private_key_screen.dart';
import 'widgets/wallet_setup_method_card.dart';

/// Entry point for importing an existing wallet. Presents the three import
/// methods as navigation cards, each opening its own flow:
///   - Private key   → [InAppImportPrivateKeyScreen]
///   - Seed phrase   → [InAppImportMnemonicScreen]
///   - Tibane backup → [InAppBackupRestoreScreen]
/// Bubbles `true` up to the caller (the wallet list) when either flow reports
/// success, so the list can refresh.
class InAppImportScreen extends StatelessWidget {
  const InAppImportScreen({super.key});

  Future<void> _open(BuildContext context, Widget screen) async {
    final done = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => screen));
    if (done == true && context.mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.inappImportTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Text(
              l10n.inappImportPrompt,
              style: const TextStyle(
                color: TibaneColors.textMuted,
                fontSize: 16,
                height: 1.4,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 24),
            WalletSetupMethodCard(
              key: const Key('wallet-import-private-key-option'),
              icon: Icons.key_outlined,
              title: l10n.inappCreateImportPrivateKeyLink,
              subtitle: l10n.walletSetupPrivateKeySubtitle,
              onTap: () => _open(context, const InAppImportPrivateKeyScreen()),
            ),
            const SizedBox(height: 12),
            WalletSetupMethodCard(
              key: const Key('wallet-import-backup-option'),
              icon: Icons.verified_user_outlined,
              title: l10n.inappImportBackupTitle,
              subtitle: l10n.inappImportBackupSubtitle,
              onTap: () => _open(context, const InAppBackupRestoreScreen()),
            ),
            const SizedBox(height: 12),
            WalletSetupMethodCard(
              key: const Key('wallet-import-seed-option'),
              icon: Icons.key_outlined,
              title: l10n.inappImportSeedTitle,
              subtitle: l10n.inappImportSeedSubtitle,
              onTap: () => _open(context, const InAppImportMnemonicScreen()),
            ),
          ],
        ),
      ),
    );
  }
}
