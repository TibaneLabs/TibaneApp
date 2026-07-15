import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/main.dart';

/// Tests for [resolveAppLocale] — the auto-detect fallback logic used as
/// MaterialApp.localeResolutionCallback when no explicit language is chosen.
void main() {
  final supported = AppLocalizations.supportedLocales; // [en, fr, ja, pt]

  group('resolveAppLocale — device language auto-detect', () {
    test('null device locale -> English', () {
      expect(resolveAppLocale(null, supported), const Locale('en'));
    });

    test('exact language matches map to themselves', () {
      expect(resolveAppLocale(const Locale('fr'), supported), const Locale('fr'));
      expect(resolveAppLocale(const Locale('ja'), supported), const Locale('ja'));
      expect(resolveAppLocale(const Locale('pt'), supported), const Locale('pt'));
    });

    test('language+country falls back to language-only match', () {
      expect(
        resolveAppLocale(const Locale('en', 'US'), supported),
        const Locale('en'),
      );
      expect(
        resolveAppLocale(const Locale('fr', 'CA'), supported),
        const Locale('fr'),
      );
      expect(
        resolveAppLocale(const Locale('ja', 'JP'), supported),
        const Locale('ja'),
      );
    });

    test('any Portuguese (pt_BR / pt_PT) resolves to pt', () {
      expect(
        resolveAppLocale(const Locale('pt', 'BR'), supported),
        const Locale('pt'),
      );
      expect(
        resolveAppLocale(const Locale('pt', 'PT'), supported),
        const Locale('pt'),
      );
    });

    test('unsupported languages fall back to English', () {
      expect(resolveAppLocale(const Locale('de', 'DE'), supported), const Locale('en'));
      expect(resolveAppLocale(const Locale('zh'), supported), const Locale('en'));
      expect(resolveAppLocale(const Locale('es'), supported), const Locale('en'));
    });

    test('exact language+country match wins over language-only', () {
      const withVariants = [Locale('pt'), Locale('pt', 'BR')];
      expect(
        resolveAppLocale(const Locale('pt', 'BR'), withVariants),
        const Locale('pt', 'BR'),
      );
      expect(
        resolveAppLocale(const Locale('pt', 'PT'), withVariants),
        const Locale('pt'),
      );
    });
  });
}
