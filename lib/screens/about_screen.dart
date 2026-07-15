import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show VersionInfo;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/cat_logo.dart';
import '../widgets/tibane_card.dart';
import '../utils/log.dart';
import '../utils/wallet_error.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  VersionInfo? _versionInfo;
  String? _versionError;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final client = await context
          .read<WalletService>()
          .libwallet
          .ensureClient();
      final v = await client.info.versionInfo();
      if (!mounted) return;
      setState(() => _versionInfo = v);
    } catch (e) {
      logError('[About._loadVersion] error: $e');
      if (!mounted) return;
      setState(() => _versionError = WalletError.from(e).message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
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
                  shaderCallback: (bounds) =>
                      TibaneColors.brandGradient.createShader(bounds),
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
                  l10n.aboutHeroTagline,
                  style: serifStyle(
                    fontSize: 18,
                    color: TibaneColors.textMuted,
                  ),
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
                  l10n.aboutStoryTitle,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: TibaneColors.text),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.aboutStoryParagraph1,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: TibaneColors.textMuted,
                    height: 1.7,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.aboutStoryParagraph2,
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
                      child: const Icon(
                        Icons.pets,
                        color: TibaneColors.gold,
                        size: 20,
                      ),
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
                _DetailRow(label: l10n.aboutTokenLaunchLabel, value: l10n.homeFairLaunch),
                _DetailRow(label: l10n.aboutTokenSupplyLabel, value: l10n.aboutTokenSupplyValue),
                _DetailRow(label: l10n.aboutTokenPresaleLabel, value: l10n.commonNone),
                _DetailRow(label: l10n.aboutTokenTeamAllocLabel, value: l10n.commonNone),
                _DetailRow(label: l10n.homeStakingTitle, value: l10n.aboutTokenStakingValue),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Links
          Text(
            l10n.aboutLinksSection,
            style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
          ),
          const SizedBox(height: 12),
          _LinkCard(
            icon: Icons.language,
            label: l10n.aboutLinkWebsite,
            url: 'https://tibane.net',
          ),
          const SizedBox(height: 8),
          _LinkCard(
            icon: Icons.chat,
            label: l10n.aboutLinkTwitter,
            url: 'https://x.com/TibaneLabs',
          ),
          const SizedBox(height: 32),

          // Diagnostics
          Text(
            l10n.aboutDiagnosticsSection,
            style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
          ),
          const SizedBox(height: 12),
          _VersionInfoCard(info: _versionInfo, error: _versionError),
          const SizedBox(height: 32),

          // Built with
          Center(
            child: Column(
              children: [
                Text(
                  l10n.aboutBuiltOnSolana,
                  style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.aboutCopyright,
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
              style: const TextStyle(
                color: TibaneColors.textMuted,
                fontSize: 13,
              ),
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

  const _LinkCard({required this.icon, required this.label, required this.url});

  @override
  Widget build(BuildContext context) {
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
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

class _VersionInfoCard extends StatelessWidget {
  final VersionInfo? info;
  final String? error;

  const _VersionInfoCard({required this.info, required this.error});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TibaneCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv(
            'libwallet',
            info?.version.isNotEmpty == true
                ? info!.version
                : (error != null ? l10n.aboutDiagUnavailable : l10n.aboutDiagLoading),
          ),
          if (info != null && info!.gitTag.isNotEmpty) _kv('git', info!.gitTag),
          if (info != null && info!.dateTag.isNotEmpty)
            _kv('build', info!.dateTag),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error!,
                style: monoStyle(fontSize: 10, color: TibaneColors.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            k,
            style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: monoStyle(fontSize: 11, color: TibaneColors.text),
          ),
        ),
      ],
    ),
  );
}
