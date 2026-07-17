import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/tibane_card.dart';
import 'incinerator_screen.dart';
import '../utils/context_extensions.dart';

/// Catalog of Tibane tools, reached from the Home "Tools" action card. Lists
/// every tool that isn't already a top-level Home action (Search, Stake).
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Incinerator is Solana-only (SPL burns), so hide it when the current
    // account isn't Solana — matching the Home chain-gating.
    final solana = context.watch<WalletService>().solanaFeaturesEnabled;

    final tools = <Widget>[
      if (solana)
        FeatureCard(
          icon: Icons.local_fire_department,
          title: 'Incinerator',
          description: l10n.homeIncineratorDescription,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                backgroundColor: TibaneColors.black,
                appBar: AppBar(title: const Text('Incinerator')),
                body: const IncineratorScreen(),
              ),
            ),
          ),
        ),
    ];

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.homeToolsCardTitle)),
      body: SafeArea(
        child: tools.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    l10n.toolsEmpty,
                    textAlign: TextAlign.center,
                    style: context.textTheme.bodyMedium?.copyWith(
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: tools.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, i) => tools[i],
              ),
      ),
    );
  }
}
