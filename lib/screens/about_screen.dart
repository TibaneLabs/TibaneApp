import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/tibane_theme.dart';
import '../widgets/cat_logo.dart';
import '../widgets/tibane_card.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          // Hero
          Center(
            child: Column(
              children: [
                const CatLogo(size: 96, glow: true),
                const SizedBox(height: 20),
                ShaderMask(
                  shaderCallback: (bounds) => TibaneColors.brandGradient.createShader(bounds),
                  child: Text(
                    'Tibane Labs',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Building on Solana',
                  style: serifStyle(fontSize: 18, color: TibaneColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Story
          TibaneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The Story',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: TibaneColors.text,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Tibane Labs is named after Tibane, a beloved cat who lived from the '
                  '1990s until 2019. Tibane was the grandmother\'s cat of Mark Karpeles, '
                  'and the inspiration behind the company name "Tibanne" — the entity '
                  'that once operated Mt.Gox.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: TibaneColors.textMuted,
                    height: 1.7,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Today, Tibane Labs develops open-source tools and infrastructure '
                  'for the Solana ecosystem, including time-weighted staking pools, '
                  'a token incinerator, and analytics tools.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: TibaneColors.textMuted,
                    height: 1.7,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Token
          TibaneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: TibaneColors.gold.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.pets, color: TibaneColors.gold, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Tibane Thecat',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: TibaneColors.gold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _DetailRow(label: 'Launch', value: 'Fair launch on pump.fun'),
                _DetailRow(label: 'Supply', value: '1B tokens (30M burned)'),
                _DetailRow(label: 'Presale', value: 'None'),
                _DetailRow(label: 'Team allocation', value: 'None'),
                _DetailRow(label: 'Staking', value: '~10% in staking pool'),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Links
          Text('LINKS', style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
          const SizedBox(height: 12),
          _LinkCard(
            icon: Icons.language,
            label: 'Website',
            url: 'https://tibane.net',
          ),
          const SizedBox(height: 8),
          _LinkCard(
            icon: Icons.chat,
            label: 'Twitter / X',
            url: 'https://x.com/TibaneLabs',
          ),
          const SizedBox(height: 32),

          // Built with
          Center(
            child: Column(
              children: [
                Text(
                  'Built on Solana',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                ),
                const SizedBox(height: 4),
                Text(
                  '2025 Tibane Labs',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(color: TibaneColors.textDim, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: TibaneColors.textMuted, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String url;

  const _LinkCard({
    required this.icon,
    required this.label,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Row(
        children: [
          Icon(icon, size: 20, color: TibaneColors.orange),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: TibaneColors.text,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Text(
            url.replaceAll('https://', ''),
            style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.open_in_new, size: 14, color: TibaneColors.textDim),
        ],
      ),
    );
  }
}
