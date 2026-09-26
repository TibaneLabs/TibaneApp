import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/tibane_theme.dart';
import '../widgets/tibane_card.dart';
import 'incinerator_screen.dart';
import 'wallet/solana_context.dart';

/// Catalog of Tibane tools, reached from the Home "Tools" action card. Lists
/// every tool that isn't already a top-level Home action (Search, Stake).
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Incinerator is Solana-only, but it remains reachable from any selected
    // account. On tap we switch to the wallet's Solana context first.
    final tools = <Widget>[
      FeatureCard(
        icon: Icons.local_fire_department,
        title: 'Incinerator',
        description: l10n.homeIncineratorDescription,
        onTap: () async {
          if (!await ensureSolanaWalletContext(context)) return;
          if (!context.mounted) return;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                backgroundColor: TibaneColors.black,
                appBar: AppBar(title: const Text('Incinerator')),
                body: const IncineratorScreen(),
              ),
            ),
          );
        },
      ),
    ];

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.homeToolsCardTitle)),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: tools.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, i) => tools[i],
        ),
      ),
    );
  }
}
