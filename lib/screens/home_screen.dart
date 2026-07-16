import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../services/uk_compliance_service.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/cat_logo.dart';
import '../widgets/tibane_card.dart';
import 'incinerator_screen.dart';
import 'staking/staking_pools_screen.dart';
import 'token_favorites_screen.dart';
import '../utils/context_extensions.dart';

class HomeScreen extends StatelessWidget {
  final void Function(int) onNavigate;

  const HomeScreen({super.key, required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          const SizedBox(height: 16),
          _HeroSection(onNavigate: onNavigate),
          const SizedBox(height: 48),
          _ToolsSection(onNavigate: onNavigate),
          const SizedBox(height: 48),
          const _AboutSection(),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _HeroSection extends StatelessWidget {
  final void Function(int) onNavigate;

  const _HeroSection({required this.onNavigate});

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

class _ToolsSection extends StatelessWidget {
  final void Function(int) onNavigate;

  const _ToolsSection({required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final isUk = context.watch<UkComplianceService>().isUk;
    // Staking + Incinerator are Solana-only (ChiefStaker program / SPL burns),
    // so hide them when the current account isn't Solana (Atonline-parity §4.5
    // chain gating). Search is chain-neutral and stays.
    final solana = context.watch<WalletService>().solanaFeaturesEnabled;

    final l10n = context.l10n;
    final cards = <Widget>[
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
      // Staking is a regulated activity in the UK — hide its entry point for UK
      // users (still reachable via third-party sites in Browse).
      if (!isUk && solana)
        FeatureCard(
          icon: Icons.account_balance,
          title: l10n.homeStakingTitle,
          description: l10n.homeStakingDescription,
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
      FeatureCard(
        icon: Icons.analytics_outlined,
        title: l10n.homeTokenInfoTitle,
        description: l10n.homeTokenInfoDescription,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TokenFavoritesScreen()),
        ),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              context.l10n.homeToolsSection,
              style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
            ),
            const SizedBox(width: 8),
            Expanded(child: Container(height: 1, color: TibaneColors.border)),
          ],
        ),
        const SizedBox(height: 20),
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          cards[i],
        ],
      ],
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
