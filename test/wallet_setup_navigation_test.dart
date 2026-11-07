import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/inapp_backup_restore_screen.dart';
import 'package:tibaneapp/screens/wallet/inapp_create_screen.dart';
import 'package:tibaneapp/screens/wallet/create_seed_wallet_screen.dart';
import 'package:tibaneapp/screens/wallet/inapp_import_mnemonic_screen.dart';
import 'package:tibaneapp/screens/wallet/inapp_import_private_key_screen.dart';
import 'package:tibaneapp/screens/wallet/inapp_import_screen.dart';
import 'package:tibaneapp/screens/wallet/wallet_create_options_screen.dart';
import 'package:tibaneapp/screens/wallet/wallet_screen.dart';
import 'package:tibaneapp/screens/wallet/wallet_welcome_screen.dart';
import 'package:tibaneapp/screens/wallet/widgets/wallet_setup_method_card.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

class _Backend extends LibwalletBackend {
  int clientRequests = 0;
  @override
  bool get hasWallet => false;
  @override
  Future<LibwalletClient> ensureClient() async {
    clientRequests++;
    throw StateError('Navigation must not initialize a native wallet');
  }
}

class _Wallet extends WalletService {
  final backend = _Backend();
  @override
  LibwalletBackend get libwallet => backend;
  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

class _Harness {
  final wallet = _Wallet();
  bool? result;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  Size size = const Size(393, 852),
  double textScale = 1,
  bool walletTab = false,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = _Harness();
  addTearDown(harness.wallet.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: harness.wallet,
      child: MaterialApp(
        locale: locale,
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: walletTab
            ? const WalletScreen()
            : Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      harness.result = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                          builder: (_) => const WalletWelcomeScreen(),
                        ),
                      );
                    },
                    child: const Text('Open setup'),
                  ),
                ),
              ),
      ),
    ),
  );
  if (!walletTab) await tester.tap(find.text('Open setup'));
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await _reveal(tester, target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      160,
      scrollable: find.byType(Scrollable).last,
    );
  } else {
    await tester.ensureVisible(target);
  }
  await tester.pumpAndSettle();
}

Future<void> _back(WidgetTester tester, Type screen, [bool? result]) async {
  Navigator.of(tester.element(find.byType(screen))).pop(result);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/local_auth'),
          (call) async =>
              call.method == 'getAvailableBiometrics' ? <String>[] : false,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/local_auth'),
          null,
        );
  });

  for (final locale in AppLocalizations.supportedLocales) {
    for (final size in [const Size(320, 568), const Size(393, 852)]) {
      for (final scale in [1.0, 1.5]) {
        testWidgets('setup layout $locale $size scale $scale', (tester) async {
          final harness = await _pump(
            tester,
            locale: locale,
            size: size,
            textScale: scale,
          );
          final l10n = AppLocalizations.of(
            tester.element(find.byType(WalletWelcomeScreen)),
          );
          expect(find.text(l10n.walletSetupWelcome), findsOneWidget);
          expect(find.byType(Image), findsOneWidget);
          expect(l10n.walletSetupWelcome, isNot(contains('Wallet')));
          final logo = tester.widget<Image>(find.byType(Image));
          expect(logo.width, closeTo(144 * 1.2, 0.001));
          expect(logo.height, closeTo(144 * 1.2, 0.001));
          final title = tester.widget<Text>(find.text(l10n.walletSetupWelcome));
          expect(title.style!.fontSize, closeTo(26 * 1.15, 0.001));
          expect(
            tester.getTopLeft(find.text(l10n.walletSetupWelcome)).dy -
                tester.getBottomLeft(find.byType(Image)).dy,
            closeTo(4, 0.001),
          );
          expect(
            tester
                    .getTopLeft(find.byKey(const Key('wallet-welcome-create')))
                    .dy -
                tester.getBottomLeft(find.text(l10n.walletSetupWelcome)).dy,
            closeTo(20, 0.001),
          );
          for (final key in [
            'wallet-welcome-create',
            'wallet-welcome-import',
          ]) {
            final button = tester.widget<FilledButton>(find.byKey(Key(key)));
            expect(
              button.style!.textStyle!.resolve({})!.fontSize,
              closeTo(18 * 1.15, 0.001),
            );
          }
          if (size.height == 852 && scale == 1) {
            final content = tester.getRect(find.byType(SingleChildScrollView));
            final scaffold = tester.widget<Scaffold>(
              find.descendant(
                of: find.byType(WalletWelcomeScreen),
                matching: find.byType(Scaffold),
              ),
            );
            final body = tester.getRect(find.byWidget(scaffold.body!));
            expect(content.center.dy, lessThan(body.center.dy));
            expect(
              tester
                  .getBottomLeft(find.byKey(const Key('wallet-welcome-import')))
                  .dy,
              lessThanOrEqualTo(body.bottom),
            );
          }
          await _tap(tester, 'wallet-welcome-create');
          final seed = tester.widget<WalletSetupMethodCard>(
            find.byKey(const Key('wallet-create-seed-option')),
          );
          expect(seed.onTap, isNotNull);
          expect(seed.unavailableLabel, isNull);
          await _reveal(
            tester,
            find.byKey(const Key('wallet-create-mpc-option')),
          );
          expect(tester.takeException(), isNull);
          await _back(tester, WalletCreateOptionsScreen);
          await _tap(tester, 'wallet-welcome-import');
          for (final key in [
            'wallet-import-private-key-option',
            'wallet-import-backup-option',
            'wallet-import-seed-option',
          ]) {
            await _reveal(tester, find.byKey(Key(key)));
            expect(tester.takeException(), isNull);
          }
          expect(harness.wallet.backend.clientRequests, 0);
        });
      }
    }
  }

  testWidgets('MPC opens its original form and back keeps the chooser', (
    tester,
  ) async {
    final harness = await _pump(tester);
    await _tap(tester, 'wallet-welcome-create');
    await _tap(tester, 'wallet-create-mpc-option');
    expect(find.byType(InAppCreateScreen), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is SegmentedButton), findsOneWidget);
    expect(find.text('Send verification code'), findsOneWidget);
    expect(find.text('Import existing wallet'), findsNothing);
    expect(harness.wallet.backend.clientRequests, 0);
    await _back(tester, InAppCreateScreen);
    expect(find.byType(WalletCreateOptionsScreen), findsOneWidget);
    expect(harness.result, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'seed creation opens without generation and preserves completion routing',
    (tester) async {
      final harness = await _pump(tester);
      await _tap(tester, 'wallet-welcome-create');
      await _tap(tester, 'wallet-create-seed-option');
      expect(find.byType(CreateSeedWalletScreen), findsOneWidget);
      expect(harness.wallet.backend.clientRequests, 0);
      await _back(tester, CreateSeedWalletScreen);
      expect(find.byType(WalletCreateOptionsScreen), findsOneWidget);
      await _tap(tester, 'wallet-create-seed-option');
      await _back(tester, CreateSeedWalletScreen, true);
      expect(harness.result, true);
      expect(find.text('Open setup'), findsOneWidget);
    },
  );

  testWidgets('MPC success returns through both menus to the caller', (
    tester,
  ) async {
    final harness = await _pump(tester);
    await _tap(tester, 'wallet-welcome-create');
    await _tap(tester, 'wallet-create-mpc-option');
    await _back(tester, InAppCreateScreen, true);
    expect(find.text('Open setup'), findsOneWidget);
    expect(harness.result, true);
    expect(find.byType(WalletWelcomeScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final (key, screen) in [
    ('wallet-import-private-key-option', InAppImportPrivateKeyScreen),
    ('wallet-import-backup-option', InAppBackupRestoreScreen),
    ('wallet-import-seed-option', InAppImportMnemonicScreen),
  ]) {
    testWidgets('$key preserves cancel and successful completion', (
      tester,
    ) async {
      final harness = await _pump(tester);
      await _tap(tester, 'wallet-welcome-import');
      await _tap(tester, key);
      expect(find.byType(screen), findsOneWidget);
      await _back(tester, screen);
      expect(find.byType(InAppImportScreen), findsOneWidget);
      expect(harness.result, isNull);
      await _tap(tester, key);
      await _back(tester, screen, true);
      expect(harness.result, true);
      expect(find.text('Open setup'), findsOneWidget);
      expect(harness.wallet.backend.clientRequests, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty wallet tab opens welcome without an extra gate', (
    tester,
  ) async {
    await _pump(tester, walletTab: true);
    final welcome = tester.widget<WalletWelcomeScreen>(
      find.byType(WalletWelcomeScreen),
    );
    expect(welcome.showBackButton, false);
    expect(find.byType(BackButton), findsNothing);
    await _tap(tester, 'wallet-welcome-import');
    await _tap(tester, 'wallet-import-seed-option');
    await _back(tester, InAppImportMnemonicScreen, true);
    expect(find.byType(WalletScreen), findsOneWidget);
    expect(find.byType(WalletWelcomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
