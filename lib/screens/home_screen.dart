import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../services/uk_compliance_service.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/cat_logo.dart';
import '../widgets/tibane_card.dart';
import 'staking/staking_pools_screen.dart';
import 'token_favorites_screen.dart';
import 'tools_screen.dart';
import '../utils/context_extensions.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const _HeroSection(),
          const SizedBox(height: 48),
          const _HomeActions(),
          const SizedBox(height: 48),
          const _AboutSection(),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _HeroSection extends StatelessWidget {
  const _HeroSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Ambient glow
        Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [
                TibaneColors.orange.withValues(alpha: 0.08),
                Colors.transparent,
              ],
              radius: 0.8,
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            children: [
              const CatLogo(size: 80, glow: true),
              const SizedBox(height: 24),
              ShaderMask(
                shaderCallback: (bounds) =>
                    TibaneColors.brandGradient.createShader(bounds),
                child: Text(
                  'Tibane Labs',
                  style: context.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -1,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.homeHeroSubtitle,
                textAlign: TextAlign.center,
                style: context.textTheme.bodyLarge?.copyWith(
                  color: TibaneColors.textMuted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: TibaneColors.cyan,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: TibaneColors.cyan.withValues(alpha: 0.5),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.homeLiveOnSolana,
                    style: monoStyle(fontSize: 10, color: TibaneColors.cyan),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Which of the three Home actions are visible for the current account context.
/// Tools + Stake are Solana-only (Incinerator burns / ChiefStaker program), and
/// Stake is additionally hidden for UK users (staking is a regulated activity).
/// Search is chain-neutral and always shown. Pure, for unit testing.
@visibleForTesting
({bool tools, bool search, bool stake}) homeActionVisibility({
  required bool isUk,
  required bool solana,
}) => (tools: solana, search: true, stake: solana && !isUk);

/// The top-level Home actions, laid out horizontally: Tools (a catalog of the
/// remaining tools), Search (token info / favorites) and Stake (staking pools).
/// The row collapses to whichever actions [homeActionVisibility] allows.
class _HomeActions extends StatelessWidget {
  const _HomeActions();

  @override
  Widget build(BuildContext context) {
    final isUk = context.watch<UkComplianceService>().isUk;
    final solana = context.watch<WalletService>().solanaFeaturesEnabled;
    final vis = homeActionVisibility(isUk: isUk, solana: solana);
    final l10n = context.l10n;

    final actions = <Widget>[
      if (vis.tools)
        _HomeActionCard(
          icon: Icons.handyman_outlined,
          title: l10n.homeToolsCardTitle,
          description: l10n.homeToolsCardDesc,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ToolsScreen()),
          ),
        ),
      if (vis.search)
        _HomeActionCard(
          icon: Icons.search,
          title: l10n.homeTokenInfoTitle,
          description: l10n.homeTokenInfoDescription,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TokenFavoritesScreen()),
          ),
        ),
      if (vis.stake)
        _HomeActionCard(
          icon: Icons.layers_outlined,
          title: l10n.homeStakeCardTitle,
          description: l10n.homeStakeCardDesc,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                backgroundColor: TibaneColors.black,
                appBar: AppBar(title: Text(l10n.homeStakingPoolsTitle)),
                body: const SafeArea(child: StakingPoolsScreen()),
              ),
            ),
          ),
        ),
    ];

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: actions[i]),
          ],
        ],
      ),
    );
  }
}

/// A compact, vertically-stacked Home action tile: icon, title, short blurb.
class _HomeActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _HomeActionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TibaneCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: TibaneColors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, color: TibaneColors.orange, size: 22),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: context.textTheme.titleMedium?.copyWith(
              color: TibaneColors.text,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: context.textTheme.bodySmall?.copyWith(
              color: TibaneColors.textMuted,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return TibaneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: TibaneColors.purple.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.pets,
                  color: TibaneColors.purple,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tibane Thecat',
                      style: context.textTheme.titleMedium?.copyWith(
                        color: TibaneColors.gold,
                      ),
                    ),
                    Text(
                      context.l10n.homeFairLaunch,
                      style: context.textTheme.bodySmall?.copyWith(
                        color: TibaneColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.homeAboutDescription,
            style: context.textTheme.bodyMedium?.copyWith(
              color: TibaneColors.textMuted,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: () => launchUrl(Uri.parse('https://tibane.net')),
            child: Text(
              'tibane.net',
              style: TextStyle(
                color: TibaneColors.orange,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
