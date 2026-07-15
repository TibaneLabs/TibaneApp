import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/locale_controller.dart';

/// Tests for [LocaleController] — encode/decode helpers and the
/// load / setLocale persistence round-trip (including "System default").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encode / decode', () {
    test('language-only round-trips', () {
      expect(LocaleController.encode(const Locale('fr')), 'fr');
      expect(LocaleController.decode('fr'), const Locale('fr'));
    });

    test('language+country round-trips', () {
      expect(LocaleController.encode(const Locale('pt', 'BR')), 'pt_BR');
      expect(LocaleController.decode('pt_BR'), const Locale('pt', 'BR'));
    });

    test('null / empty decodes to null (System default)', () {
      expect(LocaleController.decode(null), isNull);
      expect(LocaleController.decode(''), isNull);
    });
  });

  group('sameLocale', () {
    test('two nulls are equal', () {
      expect(LocaleController.sameLocale(null, null), isTrue);
    });
    test('null vs value not equal', () {
      expect(LocaleController.sameLocale(null, const Locale('en')), isFalse);
    });
    test('matches on language + country', () {
      expect(
        LocaleController.sameLocale(const Locale('pt', 'BR'), const Locale('pt', 'BR')),
        isTrue,
      );
      expect(
        LocaleController.sameLocale(const Locale('pt'), const Locale('pt', 'BR')),
        isFalse,
      );
    });
  });

  group('persistence', () {
    test('load restores a saved locale', () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'ja'});
      final c = LocaleController();
      await c.load();
      expect(c.isReady, isTrue);
      expect(c.locale, const Locale('ja'));
      expect(c.isSelected(const Locale('ja')), isTrue);
      expect(c.isSelected(null), isFalse);
    });

    test('no saved value => System default (null)', () async {
      SharedPreferences.setMockInitialValues({});
      final c = LocaleController();
      await c.load();
      expect(c.locale, isNull);
      expect(c.isSelected(null), isTrue);
    });

    test('setLocale persists and notifies once', () async {
      SharedPreferences.setMockInitialValues({});
      final c = LocaleController();
      await c.load();
      var notified = 0;
      c.addListener(() => notified++);

      await c.setLocale(const Locale('fr'));
      expect(c.locale, const Locale('fr'));
      expect(notified, 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_locale'), 'fr');
    });

    test('setLocale(null) clears the stored value', () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'fr'});
      final c = LocaleController();
      await c.load();

      await c.setLocale(null);
      expect(c.locale, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_locale'), isNull);
    });

    test('setLocale is a no-op when unchanged (no notify)', () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'fr'});
      final c = LocaleController();
      await c.load();
      var notified = 0;
      c.addListener(() => notified++);

      await c.setLocale(const Locale('fr'));
      expect(notified, 0);
    });
  });
}
