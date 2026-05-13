import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/favorites_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/cat_logo.dart';
import '../widgets/tibane_card.dart';
import 'incinerator_screen.dart';
import 'staking/staking_pools_screen.dart';
import 'token_info_screen.dart';

class HomeScreen extends StatelessWidget {
  final void Function(int) onNavigate;
  final void Function(String mint) onNavigateToToken;

  const HomeScreen({super.key, required this.onNavigate, required this.onNavigateToToken});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          const SizedBox(height: 16),
          // Hero section
          _HeroSection(onNavigate: onNavigate),
          const SizedBox(height: 48),
          // Favorites section
          _FavoritesSection(onNavigateToToken: onNavigateToToken),
          // Tools grid
          _ToolsSection(onNavigate: onNavigate),
          const SizedBox(height: 48),
          // About section
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
                shaderCallback: (bounds) => TibaneColors.brandGradient.createShader(bounds),
                child: Text(
                  'Tibane Labs',
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -1,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Research, development and tools\nfor the Solana ecosystem',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
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
                    'LIVE ON SOLANA',
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'TOOLS',
              style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(height: 1, color: TibaneColors.border),
            ),
          ],
        ),
        const SizedBox(height: 20),
        FeatureCard(
          icon: Icons.local_fire_department,
          title: 'Incinerator',
          description: 'Burn unwanted tokens, NFTs, and domains. Reclaim SOL from closed accounts.',
          badge: 'LIVE',
          badgeColor: TibaneColors.cyan,
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
        const SizedBox(height: 12),
        FeatureCard(
          icon: Icons.account_balance,
          title: 'Staking',
          description: 'Time-weighted staking pools with exponential decay rewards.',
          badge: 'LIVE',
          badgeColor: TibaneColors.cyan,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                backgroundColor: TibaneColors.black,
                appBar: AppBar(title: const Text('Staking pools')),
                body: const SafeArea(child: StakingPoolsScreen()),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FeatureCard(
          icon: Icons.swap_horiz,
          title: 'Swap',
          description: 'Swap tokens directly via Jupiter with minimal fees.',
          badge: 'LIVE',
          badgeColor: TibaneColors.cyan,
          onTap: () => onNavigate(1),
        ),
        const SizedBox(height: 12),
        FeatureCard(
          icon: Icons.analytics_outlined,
          title: 'Token Info',
          description: 'Real-time token analytics, holder distribution, and transaction history.',
          badge: 'LIVE',
          badgeColor: TibaneColors.cyan,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                backgroundColor: TibaneColors.black,
                appBar: AppBar(title: const Text('Token info')),
                body: const TokenInfoScreen(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FavoritesSection extends StatelessWidget {
  final void Function(String mint) onNavigateToToken;

  const _FavoritesSection({required this.onNavigateToToken});

  @override
  Widget build(BuildContext context) {
    return Consumer<FavoritesService>(
      builder: (context, favs, _) {
        if (favs.favorites.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.star, size: 14, color: TibaneColors.gold),
                const SizedBox(width: 6),
                Text(
                  'FAVORITES',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(height: 1, color: TibaneColors.border),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final fav in favs.favorites) ...[
              TibaneCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                onTap: () => onNavigateToToken(fav.mint),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: TibaneColors.darker,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: fav.imageUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.network(
                                fav.imageUrl!,
                                width: 36,
                                height: 36,
                                fit: BoxFit.cover,
                                errorBuilder: (_, e, s) => const Icon(
                                  Icons.token,
                                  size: 18,
                                  color: TibaneColors.textDim,
                                ),
                              ),
                            )
                          : const Icon(Icons.token, size: 18, color: TibaneColors.textDim),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fav.name ?? fav.symbol ?? 'Unknown',
                            style: const TextStyle(
                              color: TibaneColors.text,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (fav.symbol != null)
                            Text(
                              '\$${fav.symbol}',
                              style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                            ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18, color: TibaneColors.textDim),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 40),
          ],
        );
      },
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
                child: const Icon(Icons.pets, color: TibaneColors.purple, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tibane Thecat',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: TibaneColors.gold,
                      ),
                    ),
                    Text(
                      'Fair launch on pump.fun',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
            'Named after Tibane, a cat who lived from the 1990s to 2019 '
            'and inspired the company name Tibanne.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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

