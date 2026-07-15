import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import 'inapp_backup_restore_screen.dart';
import 'inapp_import_mnemonic_screen.dart';

/// Entry point for importing an existing wallet. Presents the two import
/// methods as navigation cards, each opening its own flow:
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
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          children: [
            Text(
              l10n.inappImportPrompt,
              style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
            ),
            const SizedBox(height: 16),
            _MethodCard(
              icon: Icons.vpn_key_outlined,
              title: l10n.inappImportSeedTitle,
              subtitle: l10n.inappImportSeedSubtitle,
              onTap: () => _open(context, const InAppImportMnemonicScreen()),
            ),
            const SizedBox(height: 10),
            _MethodCard(
              icon: Icons.folder_open_outlined,
              title: l10n.inappImportBackupTitle,
              subtitle: l10n.inappImportBackupSubtitle,
              onTap: () => _open(context, const InAppBackupRestoreScreen()),
            ),
          ],
        ),
      ),
    );
  }
}

class _MethodCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MethodCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TibaneCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: TibaneColors.orange.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: TibaneColors.orange, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
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
                  subtitle,
                  style: const TextStyle(
                    color: TibaneColors.textMuted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, color: TibaneColors.textDim, size: 20),
        ],
      ),
    );
  }
}
