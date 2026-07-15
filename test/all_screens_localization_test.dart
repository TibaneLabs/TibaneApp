import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';

/// Cross-batch localization smoke test for the P2–P9 extraction. Samples keys
/// from every area and asserts they resolve to a non-empty string in each of
/// the four shipped locales — catching a missing/empty translation that the
/// ARB key-parity test (key presence only) wouldn't. Also spot-checks that
/// non-English locales actually differ from English (i.e. real translation, not
/// silent template fallback).
void main() {
  // One accessor per sampled key, spanning batches: contacts/home (a9),
  // swap (a5a), staking (a6), settings (P0), tokens (P1), wallet mgmt (a3),
  // networks/nfts (a4), clawd (a8), fees (a5b), backup (a2).
  final samples = <String Function(AppLocalizations)>[
    (l) => l.contactsTitle,
    (l) => l.homeToolsSection,
    (l) => l.swapButton,
    (l) => l.swapReviewTitle,
    (l) => l.stakingCooldownReady,
    (l) => l.settingsLanguageTitle,
    (l) => l.tokensTitle,
    (l) => l.walletsMgmtTitle,
    (l) => l.networksTitle,
    (l) => l.nftsTitle,
    (l) => l.clawdAgentsEmpty,
    (l) => l.feeShareSectionShareholders,
    (l) => l.bioMigTitle,
  ];

  Future<AppLocalizations> load(WidgetTester tester, Locale locale) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return l10n;
  }

  for (final code in const ['en', 'fr', 'ja', 'pt']) {
    testWidgets('sampled keys are non-empty in $code', (tester) async {
      final l10n = await load(tester, Locale(code));
      for (final get in samples) {
        expect(get(l10n).trim(), isNotEmpty);
      }
    });
  }

  testWidgets('non-English locales actually translate (swapButton)', (
    tester,
  ) async {
    final en = await load(tester, const Locale('en'));
    final fr = await load(tester, const Locale('fr'));
    final ja = await load(tester, const Locale('ja'));
    final pt = await load(tester, const Locale('pt'));
    expect(en.swapButton, 'Swap');
    expect(fr.swapButton, 'Échanger');
    expect(ja.swapButton, isNot('Swap'));
    expect(pt.swapButton, 'Trocar');
  });
}
