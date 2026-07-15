import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/locale_controller.dart';
import '../../services/uk_compliance_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../about_screen.dart';
import '../settings_screen.dart' show SettingsTile;
import 'language_screen.dart';

/// Sub-screen reached from Settings → "General". Catch-all for app-level
/// options that aren't tied to a specific wallet/security flow.
class GeneralScreen extends StatelessWidget {
  const GeneralScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final locale = context.watch<LocaleController>().locale;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.settingsGeneralTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _UkComplianceTile(),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.translate,
                title: l10n.settingsLanguageTitle,
                subtitle: languageDisplayName(l10n, locale),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LanguageScreen()),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.info_outline,
                title: l10n.generalAboutTitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      backgroundColor: TibaneColors.black,
                      appBar: AppBar(title: Text(l10n.generalAboutAppBarTitle)),
                      body: const SafeArea(child: AboutScreen()),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UkComplianceTile extends StatelessWidget {
  const _UkComplianceTile();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final uk = context.watch<UkComplianceService>();
    final country = uk.detectedCountryCode ?? 'unknown';
    final detected = country == 'GB' || country == 'GBR';
    final subtitle = detected
        ? l10n.generalUkComplianceDetected
        : (uk.isForced
              ? l10n.generalUkComplianceForced
              : l10n.generalUkComplianceRegion(country));
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                uk.isUk ? Icons.shield_outlined : Icons.public,
                color: uk.isUk ? TibaneColors.warning : TibaneColors.textMuted,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.generalUkComplianceTitle,
                      style: const TextStyle(color: TibaneColors.text, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: monoStyle(
                        fontSize: 11,
                        color: TibaneColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (!detected)
                Switch(
                  value: uk.isForced,
                  activeThumbColor: TibaneColors.orange,
                  onChanged: (v) => uk.setForceUk(v),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
