import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/uk_compliance_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/tibane_card.dart';
import 'incinerator_screen.dart';
import 'staking/staking_pools_screen.dart';
import 'token_search_screen.dart';
import 'wallet/solana_context.dart';

/// Settings entry point for staking, account cleanup and token search.
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isUk = context.watch<UkComplianceService>().isUk;
    final tools = <Widget>[
      if (!isUk)
        FeatureCard(
          key: const Key('tools-stake'),
          icon: Icons.layers_outlined,
          title: l10n.homeStakeCardTitle,
          description: l10n.homeStakeCardDesc,
          onTap: () async {
            if (!await ensureSolanaWalletContext(context)) return;
            if (!context.mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: TibaneColors.black,
                  appBar: AppBar(title: Text(l10n.homeStakingPoolsTitle)),
                  body: const SafeArea(child: StakingPoolsScreen()),
                ),
              ),
            );
          },
        ),
      FeatureCard(
        key: const Key('tools-incinerator'),
        icon: Icons.local_fire_department,
        title: l10n.incineratorTitle,
        description: l10n.homeIncineratorDescription,
        onTap: () async {
          if (!await ensureSolanaWalletContext(context)) return;
          if (!context.mounted) return;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                backgroundColor: TibaneColors.black,
                appBar: AppBar(title: Text(l10n.incineratorTitle)),
                body: const IncineratorScreen(),
              ),
            ),
          );
        },
      ),
      FeatureCard(
        key: const Key('tools-search'),
        icon: Icons.search,
        title: l10n.homeTokenInfoTitle,
        description: l10n.homeTokenInfoDescription,
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const TokenSearchScreen())),
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
