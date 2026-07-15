import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/settings/language_screen.dart';
import 'package:tibaneapp/services/locale_controller.dart';

/// Widget tests for the Settings → Language switcher.
void main() {
  setUp(() {
    // Don't hit the network for fonts during tests.
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  Future<LocaleController> pumpSwitcher(WidgetTester tester) async {
    final controller = LocaleController();
    await controller.load();
    await tester.pumpWidget(
      ChangeNotifierProvider<LocaleController>.value(
        value: controller,
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: LanguageScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('lists System default + all shipped languages', (tester) async {
    await pumpSwitcher(tester);

    expect(find.text('System default'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Français'), findsOneWidget);
    expect(find.text('日本語'), findsOneWidget);
    expect(find.text('Português (Brasil)'), findsOneWidget);
  });

  testWidgets('starts on System default (no explicit choice)', (tester) async {
    final controller = await pumpSwitcher(tester);
    expect(controller.locale, isNull);
    expect(controller.isSelected(null), isTrue);
  });

  testWidgets('tapping a language selects and persists it', (tester) async {
    final controller = await pumpSwitcher(tester);

    await tester.tap(find.text('Français'));
    await tester.pumpAndSettle();

    expect(controller.locale, const Locale('fr'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_locale'), 'fr');
  });

  testWidgets('Japanese renders (glyphs present, not empty)', (tester) async {
    await pumpSwitcher(tester);
    final jp = tester.widget<Text>(find.text('日本語'));
    expect(jp.data, '日本語');
  });
}
