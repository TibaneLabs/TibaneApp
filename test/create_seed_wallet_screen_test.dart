import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/create_seed_wallet_screen.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/logical_wallet.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

const _phrase =
    'legal winner thank year wave sausage worth useful legal winner thank yellow';

class _Backend extends LibwalletBackend {
  int generations = 0;
  int imports = 0;
  int? generatedCount;
  String? importedPhrase;
  LogicalWallet? createdGroup;
  String? importedPassphrase;
  Wallet? created;
  bool failGeneration = false;
  bool failCreation = false;
  Completer<String>? pending;

  @override
  Future<String> generateRecoveryPhrase({int words = 12}) async {
    generations++;
    generatedCount = words;
    if (failGeneration) throw StateError('fixture generation error');
    return pending?.future ?? _phrase;
  }

  @override
  Future<LogicalWallet> importMultichainMnemonicWallet({
    required String mnemonic,
    String passphrase = '',
    required String name,
    required String password,
  }) async {
    imports++;
    importedPhrase = mnemonic;
    importedPassphrase = passphrase;
    if (failCreation) throw StateError('fixture creation error');
    final members = [
      for (final curve in ['ed25519', 'secp256k1'])
        Wallet(
          id: 'created-$curve',
          name: name,
          curve: curve,
          protocol: 'mnemonic',
          threshold: 0,
          gen: 0,
          pubkey: '',
          chaincode: '',
          created: DateTime(2026),
          modified: DateTime(2026),
          keys: [
            WalletKey(
              id: 'password',
              wallet: 'created-$curve',
              type: 'Password',
              key: '',
              gen: 0,
            ),
          ],
        ),
    ];
    created = members.first;
    return createdGroup = LogicalWallet(members);
  }
}

class _Wallet extends WalletService {
  _Wallet(this.backend);
  final _Backend backend;
  bool activationWorks = true;
  int activations = 0;

  @override
  LibwalletBackend get libwallet => backend;
  @override
  List<UnifiedAccount> get accounts => [
    if (backend.created != null)
      UnifiedAccount(
        backend: AccountBackend.inapp,
        chain: 'solana',
        address: 'public-fixture-address',
        label: 'Fixture',
        walletId: backend.created!.id,
        accountId: 'fixture-account',
      ),
  ];
  @override
  Future<void> refreshAccounts() async {}
  @override
  Future<bool> setCurrentAccount(
    UnifiedAccount account, {
    String? networkId,
  }) async {
    activations++;
    return activationWorks;
  }

  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

final _boundary = GlobalKey();

Future<(_Wallet, AppLocalizations)> _pump(
  WidgetTester tester, {
  String language = 'en',
  Size size = const Size(393, 852),
  double scale = 1,
  _Backend? backend,
}) async {
  final wallet = _Wallet(backend ?? _Backend());
  addTearDown(wallet.dispose);
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: wallet,
      child: RepaintBoundary(
        key: _boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
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
          home: const CreateSeedWalletScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    wallet,
    AppLocalizations.of(tester.element(find.byType(CreateSeedWalletScreen))),
  );
}

Future<void> _reveal(WidgetTester tester, String key) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  final target = find.byKey(Key(key));
  if (target.evaluate().isEmpty) {
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
  }
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      160,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await _reveal(tester, key);
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

Future<void> _backup(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('seed-create-name')),
    'Fixture wallet',
  );
  await _tap(tester, 'seed-create-generate');
}

Future<void> _toPassword(WidgetTester tester) async {
  await _tap(tester, 'seed-create-reveal');
  await _tap(tester, 'seed-create-saved');
  await _tap(tester, 'seed-create-backup-next');
}

Future<void> _password(WidgetTester tester) async {
  await _reveal(tester, 'seed-create-password');
  await tester.enterText(
    find.byKey(const Key('seed-create-password')),
    'fixture-password',
  );
  await _reveal(tester, 'seed-create-password-confirm');
  await tester.enterText(
    find.byKey(const Key('seed-create-password-confirm')),
    'fixture-password',
  );
  await _tap(tester, 'seed-create-submit');
}

Future<void> _screenshot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '/tmp/tibane-seed-$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    if (const bool.fromEnvironment('SEED_CREATE_SCREENSHOTS')) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => '/tmp',
          );
      TibaneTheme.darkTheme;
      await GoogleFonts.pendingFonts();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });

  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final size in [const Size(320, 568), const Size(393, 852)]) {
      testWidgets('seed creation fits $language $size and never requests MPC', (
        tester,
      ) async {
        final (wallet, l10n) = await _pump(
          tester,
          language: language,
          size: size,
          scale: size.width == 320 ? 1.5 : 1,
        );
        expect(wallet.backend.generations, 0);
        expect(
          find.byWidgetPredicate((widget) => widget is SegmentedButton),
          findsNothing,
        );
        expect(find.text(l10n.mnemonicWordCountLabel), findsNothing);
        await _backup(tester);
        expect(
          tester
              .widget<Text>(find.text(l10n.seedCreateBackupBody))
              .style!
              .fontSize,
          closeTo(16 * 1.2, 0.001),
        );
        expect(wallet.backend.generatedCount, 12);
        expect(wallet.backend.imports, 0);
        expect(find.byKey(const Key('seed-create-word-0')), findsNothing);
        await _reveal(tester, 'seed-create-backup-next');
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('seed-create-backup-next')),
              )
              .onPressed,
          isNull,
        );
        await _toPassword(tester);
        expect(find.byKey(const Key('seed-create-word-0')), findsNothing);
        expect(find.text(l10n.mnemonicPasswordTitle), findsOneWidget);
        expect(find.text(l10n.seedCreateConfirmTitle), findsNothing);
        expect(find.byKey(const Key('seed-create-verify')), findsNothing);
        expect(find.byType(TextField), findsNWidgets(2));
        expect(wallet.backend.imports, 0);
        expect(find.text(l10n.labelEmail), findsNothing);
        await _password(tester);
        expect(wallet.backend.importedPhrase, _phrase);
        expect(wallet.backend.importedPassphrase, '');
        expect(wallet.backend.created!.protocol, 'mnemonic');
        expect(find.text(l10n.seedCreateDoneTitle), findsOneWidget);
        expect(find.byKey(const Key('seed-create-password')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('12 words create all six networks without a network selector', (
    tester,
  ) async {
    final (wallet, _) = await _pump(tester);
    expect(find.byKey(const Key('seed-create-network')), findsNothing);
    await _backup(tester);
    expect(wallet.backend.generatedCount, 12);
    await _toPassword(tester);
    await _password(tester);
    expect(wallet.backend.importedPhrase!.split(' '), hasLength(12));
    expect(wallet.backend.createdGroup!.wallets.map((w) => w.curve), [
      'ed25519',
      'secp256k1',
    ]);
    expect(wallet.backend.createdGroup!.chains, [
      'solana',
      'ethereum',
      'bitcoin',
      'bitcoin-cash',
      'dogecoin',
      'litecoin',
    ]);
  });

  testWidgets(
    'backup acknowledgment and password validation block premature creation',
    (tester) async {
      final (wallet, l10n) = await _pump(tester);
      await _tap(tester, 'seed-create-generate');
      expect(find.text(l10n.inappCreateErrNoName), findsOneWidget);
      expect(wallet.backend.generations, 0);
      await _backup(tester);
      await _toPassword(tester);
      expect(wallet.backend.imports, 0);
      await _tap(tester, 'seed-create-submit');
      expect(find.text(l10n.mnemonicPasswordTooShort), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('seed-create-password')),
        'fixture-password',
      );
      await tester.enterText(
        find.byKey(const Key('seed-create-password-confirm')),
        'different-password',
      );
      await _tap(tester, 'seed-create-submit');
      expect(find.text(l10n.errPasswordsMismatch), findsOneWidget);
      expect(wallet.backend.imports, 0);
    },
  );

  testWidgets(
    'backup acknowledgment is still required before the password step',
    (tester) async {
      final (wallet, _) = await _pump(tester);
      await _backup(tester);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('seed-create-saved')),
            )
            .onChanged,
        isNull,
      );
      await _tap(tester, 'seed-create-reveal');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('seed-create-backup-next')),
            )
            .onPressed,
        isNull,
      );
      await _tap(tester, 'seed-create-saved');
      await _tap(tester, 'seed-create-saved');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('seed-create-backup-next')),
            )
            .onPressed,
        isNull,
      );
      expect(wallet.backend.imports, 0);
      await _tap(tester, 'seed-create-saved');
      await _tap(tester, 'seed-create-backup-next');
      expect(find.byKey(const Key('seed-create-password')), findsOneWidget);
      expect(wallet.backend.imports, 0);
    },
  );

  testWidgets(
    'back from password returns to backup and clears passwords without regenerating the seed',
    (tester) async {
      final (wallet, l10n) = await _pump(tester);
      await _backup(tester);
      await _toPassword(tester);
      await tester.enterText(
        find.byKey(const Key('seed-create-password')),
        'fixture-password',
      );
      await tester.enterText(
        find.byKey(const Key('seed-create-password-confirm')),
        'fixture-password',
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(l10n.seedCreateBackupTitle), findsOneWidget);
      expect(find.byKey(const Key('seed-create-word-0')), findsNothing);
      expect(wallet.backend.generations, 1);
      await _tap(tester, 'seed-create-backup-next');
      for (final key in [
        'seed-create-password',
        'seed-create-password-confirm',
      ]) {
        expect(
          tester.widget<TextField>(find.byKey(Key(key))).controller!.text,
          isEmpty,
        );
      }
      await _password(tester);
      expect(wallet.backend.imports, 1);
      expect(wallet.backend.importedPhrase, _phrase);
      expect(wallet.backend.generations, 1);
    },
  );

  testWidgets('background hides words and clears typed passwords', (
    tester,
  ) async {
    await _pump(tester);
    await _backup(tester);
    await _tap(tester, 'seed-create-reveal');
    expect(find.byKey(const Key('seed-create-word-0')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byKey(const Key('seed-create-word-0')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _toPassword(tester);
    await tester.enterText(
      find.byKey(const Key('seed-create-password')),
      'fixture-password',
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('seed-create-password')))
          .controller!
          .text,
      isEmpty,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets(
    'generation failure retries, and creation retry keeps the same phrase',
    (tester) async {
      final backend = _Backend()..failGeneration = true;
      await _pump(tester, backend: backend);
      await _backup(tester);
      expect(backend.imports, 0);
      backend.failGeneration = false;
      await _tap(tester, 'seed-create-generate');
      await _toPassword(tester);
      backend.failCreation = true;
      await _password(tester);
      expect(backend.created, isNull);
      backend.failCreation = false;
      await _tap(tester, 'seed-create-submit');
      expect(backend.imports, 2);
      expect(backend.generations, 2);
      expect(backend.importedPhrase, _phrase);
    },
  );

  testWidgets(
    'repeated taps cannot generate twice while native work is pending',
    (tester) async {
      final backend = _Backend()..pending = Completer<String>();
      await _pump(tester, backend: backend);
      await tester.enterText(
        find.byKey(const Key('seed-create-name')),
        'Fixture',
      );
      final button = find.byKey(const Key('seed-create-generate'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(backend.generations, 1);
      backend.pending!.complete(_phrase);
      await tester.pumpAndSettle();
      expect(backend.imports, 0);
    },
  );

  testWidgets('opening failure never recreates an already-created wallet', (
    tester,
  ) async {
    final (wallet, l10n) = await _pump(tester);
    await _backup(tester);
    await _toPassword(tester);
    await _password(tester);
    wallet.activationWorks = false;
    await _tap(tester, 'seed-create-open');
    expect(find.text(l10n.seedCreateOpenFailed), findsOneWidget);
    await _tap(tester, 'seed-create-open');
    expect(wallet.activations, 2);
    expect(wallet.backend.imports, 1);
  });

  testWidgets('opening the created wallet activates it and returns success', (
    tester,
  ) async {
    final (wallet, _) = await _pump(tester);
    final navigator = Navigator.of(
      tester.element(find.byType(CreateSeedWalletScreen)),
    );
    final result = navigator.push<bool>(
      MaterialPageRoute(builder: (_) => const CreateSeedWalletScreen()),
    );
    await tester.pumpAndSettle();
    await _backup(tester);
    await _toPassword(tester);
    await _password(tester);
    await _tap(tester, 'seed-create-open');
    expect(await result, true);
    expect(wallet.activations, 1);
    expect(wallet.backend.imports, 1);
  });

  if (const bool.fromEnvironment('SEED_CREATE_SCREENSHOTS')) {
    for (final width in [320.0, 393.0]) {
      testWidgets('seed fixture screenshots at $width', (tester) async {
        await _pump(tester, size: Size(width, width == 320 ? 568 : 852));
        await _screenshot(tester, 'details-${width.toInt()}');
        await _backup(tester);
        await _tap(tester, 'seed-create-reveal');
        await _screenshot(tester, 'words-${width.toInt()}');
        await _tap(tester, 'seed-create-saved');
        await _tap(tester, 'seed-create-backup-next');
        await _screenshot(tester, 'password-${width.toInt()}');
      });
    }
  }
}
