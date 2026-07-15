import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_form_field/phone_form_field.dart';
import 'package:tibaneapp/l10n/fallback_localizations_delegate.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';

/// Inner delegate that only supports English and loads a marker string of the
/// locale it was asked for — so we can see which locale actually got loaded.
class _EnOnlyDelegate extends LocalizationsDelegate<String> {
  const _EnOnlyDelegate();
  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en';
  @override
  Future<String> load(Locale locale) async => 'loaded:${locale.languageCode}';
  @override
  bool shouldReload(covariant LocalizationsDelegate<String> old) => false;
}

void main() {
  const inner = _EnOnlyDelegate();
  const delegate = FallbackLocalizationsDelegate(inner, Locale('en'));

  test('claims support for every locale', () {
    expect(delegate.isSupported(const Locale('ja')), isTrue);
    expect(delegate.isSupported(const Locale('en')), isTrue);
    expect(delegate.isSupported(const Locale('xx')), isTrue);
  });

  test('preserves the wrapped delegate resource type', () {
    expect(delegate.type, String);
    expect(delegate.type, inner.type);
  });

  test('loads the real locale when the inner supports it', () async {
    expect(await delegate.load(const Locale('en')), 'loaded:en');
  });

  test('falls back to English when the inner lacks the locale', () async {
    expect(await delegate.load(const Locale('ja')), 'loaded:en');
    expect(await delegate.load(const Locale('pt')), 'loaded:en');
  });

  test('does not reload when wrapping the same inner delegate', () {
    expect(
      delegate.shouldReload(
        const FallbackLocalizationsDelegate(inner, Locale('en')),
      ),
      isFalse,
    );
  });

  // End-to-end: the real phone_form_field delegates lack `ja`. Verify wrapping
  // them silences Flutter's "locale not supported by all delegates" debug
  // warning for Japanese, and that the raw (unwrapped) delegates still trigger
  // it (so this test would catch a regression).
  testWidgets('wrapped phone delegates: no ja "not supported" warning', (
    tester,
  ) async {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString());
    try {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ja'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            for (final d in PhoneFieldLocalization.delegates)
              FallbackLocalizationsDelegate(d, const Locale('en')),
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SizedBox.shrink(),
        ),
      );
    } finally {
      FlutterError.onError = previous;
    }
    expect(
      errors.where((e) => e.contains('not supported by all')),
      isEmpty,
      reason: 'wrapping should silence the ja delegate warning',
    );
  });

  testWidgets('control: raw phone delegates DO warn for ja', (tester) async {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString());
    try {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ja'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            ...PhoneFieldLocalization.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SizedBox.shrink(),
        ),
      );
    } finally {
      FlutterError.onError = previous;
    }
    expect(
      errors.where((e) => e.contains('not supported by all')),
      isNotEmpty,
      reason: 'without wrapping, ja is unsupported by the phone delegates',
    );
  });
}
