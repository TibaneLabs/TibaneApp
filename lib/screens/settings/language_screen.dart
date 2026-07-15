import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/locale_controller.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';

/// Human-readable name for a language row. Language names are endonyms (shown
/// in their own language); a null [locale] is the "System default" option.
String languageDisplayName(AppLocalizations l10n, Locale? locale) {
  if (locale == null) return l10n.languageSystemDefault;
  switch (locale.languageCode) {
    case 'fr':
      return l10n.languageNameFrench;
    case 'ja':
      return l10n.languageNameJapanese;
    case 'pt':
      return l10n.languageNamePortugueseBrazil;
    case 'en':
    default:
      return l10n.languageNameEnglish;
  }
}

/// Settings → General → Language. Lets the user pick a fixed UI language or
/// "System default" (follow the device). Writes to [LocaleController]; the
/// change applies immediately across the whole app.
class LanguageScreen extends StatelessWidget {
  const LanguageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final controller = context.watch<LocaleController>();

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.settingsLanguageTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _LanguageOption(
              label: l10n.languageSystemDefault,
              subtitle: l10n.languageSystemDefaultSubtitle,
              selected: controller.isSelected(null),
              onTap: () => _select(context, null),
            ),
            const SizedBox(height: 6),
            for (final locale in controller.supported) ...[
              _LanguageOption(
                label: languageDisplayName(l10n, locale),
                selected: controller.isSelected(locale),
                onTap: () => _select(context, locale),
              ),
              const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }

  void _select(BuildContext context, Locale? locale) {
    context.read<LocaleController>().setLocale(locale);
    Navigator.of(context).maybePop();
  }
}

class _LanguageOption extends StatelessWidget {
  const _LanguageOption({
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TibaneCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 15,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
          if (selected)
            const Icon(Icons.check, color: TibaneColors.orange, size: 20),
        ],
      ),
    );
  }
}
