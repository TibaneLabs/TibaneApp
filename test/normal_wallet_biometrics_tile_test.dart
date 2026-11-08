import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/settings/normal_wallet_biometrics_tile.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/normal_wallet_biometrics.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

import 'helpers/normal_biometrics_fixtures.dart';

class _Backend extends LibwalletBackend {
  _Backend(this.wallet, this.vault)
    : super(normalBiometrics: NormalWalletBiometrics(vault: vault));
  final Wallet wallet;
  final FakeNormalBiometricVault vault;
  int enrollments = 0;
  @override
  String get walletId => wallet.id;
  @override
  Future<List<Wallet>> normalBiometricWallets() async => [wallet];
  @override
  Future<void> enableNormalWalletBiometrics({
    String? password,
    required NormalBiometricPrompt prompt,
  }) async {
    enrollments++;
    if (wallet.protocol == 'mnemonic' && password != 'correct-fixture') {
      throw StateError('Wrong password');
    }
    await normalWalletBiometrics.enable({
      wallet: password ?? 'fixture-key',
    }, prompt);
  }

  @override
  Future<bool> disableNormalWalletBiometrics(String reason) =>
      normalWalletBiometrics.disable([wallet.id], reason);
}

Future<(_Backend, AppLocalizations)> _pump(
  WidgetTester tester, {
  String language = 'en',
  bool privateKey = false,
  NormalBiometricKind kind = NormalBiometricKind.face,
  double width = 393,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width * 2, 568 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final vault = FakeNormalBiometricVault()..kind = kind;
  final wallet = privateKey
      ? normalBiometricWallet(protocol: 'frost', types: ['StoreKey'])
      : normalBiometricWallet();
  final backend = _Backend(wallet, vault);
  addTearDown(backend.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      theme: TibaneTheme.darkTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: NormalWalletBiometricsTile(backend: backend, wallet: wallet),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    backend,
    AppLocalizations.of(
      tester.element(find.byType(NormalWalletBiometricsTile)),
    ),
  );
}

Future<void> _consent(WidgetTester tester, AppLocalizations l10n) async {
  await tester.tap(find.byKey(const Key('normal-biometrics-switch')));
  await tester.pumpAndSettle();
  expect(find.text(l10n.normalBiometricsEnableTitle), findsOneWidget);
  final confirm = find.widgetWithText(FilledButton, l10n.actionConfirm);
  await tester.ensureVisible(confirm);
  await tester.tap(confirm);
  await tester.pumpAndSettle();
}

Future<void> _password(WidgetTester tester, String password) async {
  await tester.enterText(
    find.byKey(const Key('wallet-password-input')),
    password,
  );
  await tester.pumpAndSettle();
  final ok = find.byKey(const Key('wallet-password-ok'));
  await tester.ensureVisible(ok);
  await tester.tap(ok);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'seed opt-in asks consent and verifies password once; disabling authenticates the device',
    (tester) async {
      final (backend, l10n) = await _pump(tester);
      await _consent(tester, l10n);
      expect(backend.enrollments, 0);
      await _password(tester, 'correct-fixture');
      expect(backend.enrollments, 1);
      expect(
        tester
            .widget<Switch>(find.byKey(const Key('normal-biometrics-switch')))
            .value,
        isTrue,
      );
      backend.vault.ownerApproved = false;
      await tester.tap(find.byKey(const Key('normal-biometrics-switch')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Switch>(find.byKey(const Key('normal-biometrics-switch')))
            .value,
        isTrue,
      );
      backend.vault.ownerApproved = true;
      await tester.tap(find.byKey(const Key('normal-biometrics-switch')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Switch>(find.byKey(const Key('normal-biometrics-switch')))
            .value,
        isFalse,
      );
      expect(backend.vault.values, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wrong password never enables biometrics or stores a credential',
    (tester) async {
      final (backend, l10n) = await _pump(tester);
      await _consent(tester, l10n);
      await _password(tester, 'wrong-fixture');
      expect(backend.vault.writes, 0);
      expect(find.text(l10n.walletErrorIncorrectPassword), findsOneWidget);
      expect(
        tester
            .widget<Switch>(find.byKey(const Key('normal-biometrics-switch')))
            .value,
        isFalse,
      );
    },
  );

  testWidgets('private-key opt-in does not invent a wallet password', (
    tester,
  ) async {
    final (backend, l10n) = await _pump(tester, privateKey: true);
    await _consent(tester, l10n);
    expect(find.byKey(const Key('wallet-password-dialog')), findsNothing);
    expect(
      await backend.normalWalletBiometrics.isEnabled(backend.wallet),
      isTrue,
    );
    expect(backend.enrollments, 1);
  });

  testWidgets('unavailable device biometrics cannot enable the switch', (
    tester,
  ) async {
    final (backend, l10n) = await _pump(
      tester,
      kind: NormalBiometricKind.unavailable,
    );
    expect(
      tester
          .widget<Switch>(find.byKey(const Key('normal-biometrics-switch')))
          .onChanged,
      isNull,
    );
    expect(
      find.textContaining(l10n.normalBiometricsUnavailable),
      findsOneWidget,
    );
    expect(backend.vault.writes, 0);
  });

  testWidgets(
    'declining enrollment consent does not request or save a password',
    (tester) async {
      final (backend, l10n) = await _pump(tester);
      await tester.tap(find.byKey(const Key('normal-biometrics-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, l10n.actionCancel));
      await tester.pumpAndSettle();
      expect(backend.enrollments, 0);
      expect(backend.vault.writes, 0);
      expect(find.byKey(const Key('wallet-password-input')), findsNothing);
    },
  );

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'biometric settings and consent fit ${locale.languageCode} at 320px with large text',
      (tester) async {
        final (_, l10n) = await _pump(
          tester,
          language: locale.languageCode,
          width: 320,
          scale: 1.5,
        );
        expect(find.text(l10n.normalBiometricsFaceTitle), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('normal-biometrics-switch')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final cancel = find.widgetWithText(TextButton, l10n.actionCancel);
        await tester.ensureVisible(cancel);
        await tester.tap(cancel);
        await tester.pumpAndSettle();
      },
    );
  }
}
