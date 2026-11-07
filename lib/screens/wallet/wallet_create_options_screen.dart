import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/tibane_theme.dart';
import 'inapp_create_screen.dart';
import 'create_seed_wallet_screen.dart';
import 'widgets/wallet_setup_method_card.dart';

class WalletCreateOptionsScreen extends StatelessWidget {
  const WalletCreateOptionsScreen({super.key});

  Future<void> _createMpc(BuildContext context) async {
    final done = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const InAppCreateScreen()));
    if (done == true && context.mounted) Navigator.of(context).pop(true);
  }

  Future<void> _createSeed(BuildContext context) async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateSeedWalletScreen()),
    );
    if (done == true && context.mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.inappCreateButton)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Text(
              l10n.walletSetupCreatePrompt,
              style: const TextStyle(
                color: TibaneColors.textMuted,
                fontSize: 16,
                height: 1.4,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 24),
            WalletSetupMethodCard(
              key: const Key('wallet-create-seed-option'),
              icon: Icons.key_outlined,
              title: l10n.walletSetupSeedTitle,
              subtitle: l10n.walletSetupSeedSubtitle,
              centered: true,
              onTap: () => _createSeed(context),
            ),
            const SizedBox(height: 12),
            WalletSetupMethodCard(
              key: const Key('wallet-create-mpc-option'),
              icon: Icons.verified_user_outlined,
              title: l10n.inappCreateTitle,
              subtitle: l10n.walletSetupMpcSubtitle,
              centered: true,
              onTap: () => _createMpc(context),
            ),
          ],
        ),
      ),
    );
  }
}
