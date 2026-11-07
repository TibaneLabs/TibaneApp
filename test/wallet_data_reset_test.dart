import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/wallet_data_reset_screen.dart';
import 'package:tibaneapp/screens/wallet/inapp_export_screen.dart';
import 'package:tibaneapp/services/wallet/accounts_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/mwa_wallet_backend.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/services/wallet_service.dart';

class _BackupTransport implements Transport {
  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    if (path == 'Wallet' && verb == 'GET') return <dynamic>[];
    throw StateError('Unexpected call $verb $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  @override
  final WalletApi wallets = WalletApi(_BackupTransport());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  final client = _Client();
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

class _Service extends WalletService {
  final backend = _Backend();
  int removals = 0;
  @override
  LibwalletBackend get libwallet => backend;
  @override
  Future<bool> removeAllWalletsFromDevice() async {
    removals++;
    return true;
  }

  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

Future<AppLocalizations> _pumpReset(
  WidgetTester tester,
  _Service service,
  String language,
  Size size,
) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: service,
      child: MaterialApp(
        theme: TibaneTheme.darkTheme,
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const WalletDataResetScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return AppLocalizations.of(
    tester.element(find.byType(WalletDataResetScreen)),
  );
}

Future<void> _next(WidgetTester tester, AppLocalizations l10n) async {
  await tester.tap(find.text(l10n.actionNext));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final size in [const Size(320, 568), const Size(393, 852)]) {
      testWidgets(
        'reset warning typography and confirmation in $language at $size',
        (tester) async {
          final service = _Service();
          addTearDown(service.dispose);
          final l10n = await _pumpReset(tester, service, language, size);
          final context = tester.element(find.byType(WalletDataResetScreen));
          final theme = Theme.of(context);
          expect(
            tester
                .widget<Text>(find.text(l10n.walletResetTitle))
                .style!
                .fontSize,
            closeTo(theme.appBarTheme.titleTextStyle!.fontSize! * 1.15, 0.001),
          );
          final titles = [
            l10n.walletResetStepOneTitle,
            l10n.walletResetStepTwoTitle,
            l10n.walletResetStepThreeTitle,
            l10n.walletResetFinalTitle,
          ];
          final bodies = [
            l10n.walletResetStepOneBody,
            l10n.walletResetStepTwoBody,
            l10n.walletResetStepThreeBody,
            l10n.walletResetFinalBody(l10n.walletResetConfirmationWord),
          ];
          for (var i = 0; i < 4; i++) {
            expect(
              tester.widget<Text>(find.text(titles[i])).style!.fontSize,
              closeTo(theme.textTheme.headlineSmall!.fontSize! * 1.15, 0.001),
            );
            expect(
              tester.widget<Text>(find.text(bodies[i])).style!.fontSize,
              18,
            );
            expect(
              find.byKey(const Key('wallet-reset-backup')),
              i == 2 ? findsOneWidget : findsNothing,
            );
            expect(service.removals, 0);
            expect(tester.takeException(), isNull);
            if (i < 3) await _next(tester, l10n);
          }
          final remove = find.widgetWithText(
            FilledButton,
            l10n.walletResetRemoveAction,
          );
          expect(find.text(l10n.walletResetAgreement), findsOneWidget);
          expect(tester.widget<FilledButton>(remove).onPressed, isNull);
          await tester.ensureVisible(find.byType(TextField));
          await tester.enterText(find.byType(TextField), 'wrong confirmation');
          await tester.pump();
          expect(tester.widget<FilledButton>(remove).onPressed, isNull);
          await tester.enterText(
            find.byType(TextField),
            l10n.walletResetConfirmationWord,
          );
          await tester.pump();
          expect(tester.widget<FilledButton>(remove).onPressed, isNotNull);
          tester.testTextInput.hide();
          await tester.ensureVisible(remove);
          await tester.pumpAndSettle();
          await tester.tap(remove);
          await tester.pumpAndSettle();
          expect(service.removals, 1);
          expect(find.text(l10n.walletResetSuccessTitle), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      'backup link opens export and returns to warnings in $language',
      (tester) async {
        final service = _Service();
        addTearDown(service.dispose);
        final l10n = await _pumpReset(
          tester,
          service,
          language,
          const Size(393, 852),
        );
        await _next(tester, l10n);
        await _next(tester, l10n);
        final link = find.byKey(const Key('wallet-reset-backup'));
        expect(
          tester.widget<TextButton>(link).style!.foregroundColor!.resolve({}),
          TibaneColors.orange,
        );
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(find.byType(InAppExportScreen), findsOneWidget);
        expect(service.removals, 0);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text(l10n.walletResetStepThreeTitle), findsOneWidget);
        expect(find.byType(InAppExportScreen), findsNothing);
        expect(service.removals, 0);
        await _next(tester, l10n);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, l10n.walletResetRemoveAction),
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  group('wallet reset confirmation', () {
    test('accepts the localized word with whitespace and different case', () {
      expect(walletResetConfirmationMatches(' confirmar ', 'Confirmar'), true);
      expect(walletResetConfirmationMatches('CONFIRM', 'Confirm'), true);
      expect(walletResetConfirmationMatches('確認', '確認'), true);
    });

    test('rejects any other text', () {
      expect(walletResetConfirmationMatches('confirmado', 'Confirmar'), false);
      expect(walletResetConfirmationMatches('', 'Confirmar'), false);
    });
  });

  test('account reset clears wallet-specific preferences', () async {
    SharedPreferences.setMockInitialValues({
      'current_account_id': 'account-1',
      'account_preferred_chains': '{"account-1":"solana"}',
      'attached_wallet_parents_v1': '{"child":"parent"}',
      'wallet_defaults_ensured_v2': <String>['wallet-1'],
      'app_locale': 'pt',
    });
    final service = AccountsService(LibwalletBackend(), MwaWalletBackend());

    await service.clearLocalWalletState();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('current_account_id'), isNull);
    expect(prefs.getString('account_preferred_chains'), isNull);
    expect(prefs.getString('attached_wallet_parents_v1'), isNull);
    expect(prefs.getStringList('wallet_defaults_ensured_v2'), isNull);
    expect(prefs.getString('app_locale'), 'pt');
    expect(service.accounts, isEmpty);
    expect(service.current, isNull);
  });

  testWidgets('Portuguese warning flow fits an iPhone SE', (tester) async {
    tester.view.physicalSize = const Size(750, 1334);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: TibaneTheme.darkTheme,
        locale: const Locale('pt'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const WalletDataResetScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text('Todos os dados das carteiras sairão deste dispositivo'),
      findsOneWidget,
    );

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Próximo'));
      await tester.pumpAndSettle();
    }

    expect(find.text('Confirmação final'), findsOneWidget);
    var removeButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Remover todas as carteiras'),
    );
    expect(removeButton.onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Confirmar');
    await tester.pump();
    removeButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Remover todas as carteiras'),
    );
    expect(removeButton.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
