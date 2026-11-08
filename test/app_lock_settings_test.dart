import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/settings/security_privacy_screen.dart';
import 'package:tibaneapp/services/app_lock_controller.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

import 'helpers/app_lock_fakes.dart';

Future<void> _pump(
  WidgetTester tester,
  AppLockController lock, {
  String language = 'en',
  double width = 393,
}) async {
  tester.view.physicalSize = Size(width * 2, 852 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final wallet = WalletService();
  addTearDown(wallet.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WalletService>.value(value: wallet),
        ChangeNotifierProvider<AppLockController>.value(value: lock),
      ],
      child: MaterialApp(
        theme: TibaneTheme.darkTheme,
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SecurityPrivacyScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'global app lock is available with no wallet and does not require a wallet password',
    (tester) async {
      final auth = FakeAppLockAuthenticator();
      final lock = AppLockController(authenticator: auth);
      addTearDown(lock.dispose);
      await lock.load();
      await _pump(tester, lock);
      expect(find.byKey(const Key('app-lock-setting')), findsOneWidget);
      expect(find.byKey(const Key('normal-wallet-biometrics')), findsNothing);
      await tester.tap(find.byKey(const Key('app-lock-switch')));
      await tester.pumpAndSettle();
      expect(lock.enabled, isTrue);
      expect(auth.policies, [true]);
      expect(find.byKey(const Key('wallet-password-dialog')), findsNothing);
      expect(
        tester.widget<Switch>(find.byKey(const Key('app-lock-switch'))).value,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('app-lock-switch')));
      await tester.pumpAndSettle();
      expect(lock.enabled, isFalse);
      expect(auth.policies, [true, false]);
    },
  );

  testWidgets('unavailable biometrics cannot enable app lock', (tester) async {
    final auth = FakeAppLockAuthenticator()
      ..kind = AppLockBiometricKind.unavailable;
    final lock = AppLockController(authenticator: auth);
    addTearDown(lock.dispose);
    await lock.load();
    await _pump(tester, lock);
    expect(
      tester.widget<Switch>(find.byKey(const Key('app-lock-switch'))).onChanged,
      isNull,
    );
    expect(auth.calls, 0);
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'app-lock option fits ${locale.languageCode} without a wallet',
      (tester) async {
        final lock = AppLockController(
          authenticator: FakeAppLockAuthenticator(),
        );
        addTearDown(lock.dispose);
        await lock.load();
        await _pump(tester, lock, language: locale.languageCode, width: 320);
        final l10n = await AppLocalizations.delegate.load(locale);
        expect(find.text(l10n.appLockFaceTitle), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
