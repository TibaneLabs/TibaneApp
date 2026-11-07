import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/inapp_import_mnemonic_screen.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/logical_wallet.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

class _Backend extends LibwalletBackend {
  int imports = 0;
  bool fail = false;
  String? importedPhrase;
  LogicalWallet? importedGroup;
  String? activeWallet;
  @override
  bool get hasWallet => activeWallet != null;
  @override
  Future<LogicalWallet> importMultichainMnemonicWallet({
    required String mnemonic,
    String passphrase = '',
    required String name,
    required String password,
  }) async {
    imports++;
    importedPhrase = mnemonic;
    if (fail) throw StateError('offline import failure');
    return importedGroup = LogicalWallet([
      for (final curve in ['ed25519', 'secp256k1'])
        Wallet(
          id: 'fixture-$curve',
          name: name,
          curve: curve,
          protocol: 'mnemonic',
          threshold: 0,
          gen: 0,
          pubkey: 'master-key-not-an-account-address',
          chaincode: '',
          created: DateTime(2026),
          modified: DateTime(2026),
          keys: [
            WalletKey(
              id: 'password',
              wallet: 'fixture-$curve',
              type: 'Password',
              key: '',
              gen: 0,
            ),
          ],
        ),
    ]);
  }
}

class _Wallet extends WalletService {
  _Wallet(this.backend);
  final _Backend backend;
  bool activationWorks = true;
  int activations = 0;
  UnifiedAccount? selected;
  @override
  LibwalletBackend get libwallet => backend;
  @override
  List<UnifiedAccount> get accounts => [
    const UnifiedAccount(
      backend: AccountBackend.inapp,
      chain: 'solana',
      address: 'unrelated-address',
      label: 'Unrelated',
      walletId: 'unrelated',
      accountId: 'unrelated-account',
    ),
    for (final wallet in backend.importedGroup?.wallets.reversed ?? <Wallet>[])
      UnifiedAccount(
        backend: AccountBackend.inapp,
        chain: wallet.curve == 'ed25519' ? 'solana' : 'ethereum',
        address: 'public-${wallet.id}',
        label: 'Imported',
        walletId: wallet.id,
        accountId: 'account-${wallet.id}',
        isMainWalletContext: true,
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
    if (!activationWorks) return false;
    selected = account;
    backend.activeWallet = account.walletId;
    return true;
  }

  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

Future<AppLocalizations> _pump(
  WidgetTester tester, {
  String language = 'en',
  Size size = const Size(393, 852),
  _Backend? backend,
  _Wallet? service,
  bool inRoute = false,
}) async {
  final wallet = service ?? _Wallet(backend ?? _Backend());
  addTearDown(wallet.dispose);
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: wallet,
      child: MaterialApp(
        locale: Locale(language),
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: inRoute
            ? Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const InAppImportMnemonicScreen(),
                      ),
                    ),
                    child: const Text('Open importer'),
                  ),
                ),
              )
            : const InAppImportMnemonicScreen(),
      ),
    ),
  );
  if (inRoute) await tester.tap(find.text('Open importer'));
  await tester.pumpAndSettle();
  return AppLocalizations.of(
    tester.element(find.byType(InAppImportMnemonicScreen)),
  );
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    target,
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

TextField _word(WidgetTester tester, int index) =>
    tester.widget<TextField>(find.byKey(ValueKey('mnemonic-word-$index')));

Future<void> _toPassword(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('mnemonic-word-0')), _phrase);
  await tester.pumpAndSettle();
  await _tap(tester, find.byKey(const Key('mnemonic-confirm-words')));
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final size in [const Size(320, 667), const Size(393, 852)]) {
      testWidgets('separate phrase and password steps fit $language $size', (
        tester,
      ) async {
        final l10n = await _pump(tester, language: language, size: size);
        expect(find.text(l10n.mnemonicInputHint), findsOneWidget);
        expect(find.byKey(const Key('mnemonic-password')), findsNothing);
        expect(find.text(l10n.mnemonicPassphraseLabel), findsNothing);
        expect(find.textContaining('BIP-39'), findsNothing);
        expect(find.textContaining('ed25519'), findsNothing);
        expect(find.byType(SegmentedButton<String>), findsNothing);

        await _toPassword(tester);
        expect(find.text(l10n.mnemonicPasswordTitle), findsOneWidget);
        expect(find.byKey(const Key('mnemonic-word-0')), findsNothing);
        expect(find.byKey(const Key('mnemonic-password')), findsOneWidget);
        expect(
          find.byKey(const Key('mnemonic-confirm-password')),
          findsOneWidget,
        );
        expect(find.text(l10n.mnemonicExtraPasswordTitle), findsOneWidget);
        expect(find.text(l10n.mnemonicExtraPasswordHint), findsNothing);
        expect(find.text(l10n.mnemonicPassphraseLabel), findsNothing);
        await _tap(tester, find.byKey(const Key('mnemonic-extra-password')));
        expect(find.text(l10n.mnemonicExtraPasswordHint), findsOneWidget);
        expect(find.text(l10n.mnemonicPassphraseLabel), findsOneWidget);
        await _tap(
          tester,
          find.byKey(const Key('mnemonic-confirm-password-step')),
        );
        expect(find.text(l10n.mnemonicPasswordTooShort), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('mnemonic-password')),
          -180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(
          find.byKey(const Key('mnemonic-password')),
          'fixture-password',
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('mnemonic-confirm-password')),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(
          find.byKey(const Key('mnemonic-confirm-password')),
          'fixture-password',
        );
        await _tap(
          tester,
          find.byKey(const Key('mnemonic-confirm-password-step')),
        );
        expect(find.byKey(const Key('mnemonic-done-title')), findsOneWidget);
        expect(find.text(l10n.labelEmail), findsNothing);
        expect(find.text(l10n.labelVerificationCode), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('incomplete words cannot advance and no wallet is created', (
    tester,
  ) async {
    final l10n = await _pump(tester);
    await _tap(tester, find.byKey(const Key('mnemonic-confirm-words')));
    expect(find.text(l10n.mnemonicCompleteWords), findsOneWidget);
    expect(find.byKey(const Key('mnemonic-password')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final count in [12, 15, 18, 21, 24]) {
    testWidgets('pasting $count words distributes every word in order', (
      tester,
    ) async {
      final l10n = await _pump(tester);
      final words = List.generate(count, (index) => 'word$index');
      await tester.enterText(
        find.byKey(const Key('mnemonic-word-1')),
        words.join('\u3000'),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.mnemonicWordCount(count)), findsOneWidget);
      for (var index = 0; index < count; index++) {
        expect(_word(tester, index).controller!.text, words[index]);
      }
      expect(find.byKey(ValueKey('mnemonic-word-$count')), findsNothing);
      await _tap(tester, find.byKey(const Key('mnemonic-confirm-words')));
      expect(find.text(l10n.mnemonicPasswordTitle), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('invalid paste is not silently truncated', (tester) async {
    final l10n = await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('mnemonic-word-0')),
      'one two three four',
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('mnemonic-confirm-words')));
    expect(find.text(l10n.mnemonicCompleteWords), findsOneWidget);
    expect(find.byKey(const Key('mnemonic-password')), findsNothing);
  });

  testWidgets('multiline paste preserves word boundaries', (tester) async {
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('mnemonic-word-0')),
      _phrase.replaceAll(' ', '\r\n'),
    );
    await tester.pumpAndSettle();
    expect(_word(tester, 0).controller!.text, 'abandon');
    expect(_word(tester, 11).controller!.text, 'about');
    await _tap(tester, find.byKey(const Key('mnemonic-confirm-words')));
    expect(find.byKey(const Key('mnemonic-password')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing word count clears hidden words', (tester) async {
    final l10n = await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('mnemonic-word-0')),
      List.filled(24, 'abandon').join(' '),
    );
    await tester.pumpAndSettle();
    final dropdown = find.byKey(const Key('mnemonic-word-count'));
    await _tap(tester, dropdown);
    await tester.tap(find.text(l10n.mnemonicWordCount(12)).last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mnemonic-word-12')), findsNothing);
    await _tap(tester, dropdown);
    await tester.tap(find.text(l10n.mnemonicWordCount(24)).last);
    await tester.pumpAndSettle();
    expect(_word(tester, 11).controller!.text, 'abandon');
    expect(_word(tester, 12).controller!.text, isEmpty);
    expect(_word(tester, 23).controller!.text, isEmpty);
    await _tap(tester, find.byKey(const Key('mnemonic-confirm-words')));
    expect(find.text(l10n.mnemonicCompleteWords), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back preserves phrase but clears new passwords', (tester) async {
    final l10n = await _pump(tester);
    await _toPassword(tester);
    await tester.enterText(
      find.byKey(const Key('mnemonic-password')),
      'fixture-password',
    );
    await tester.enterText(
      find.byKey(const Key('mnemonic-confirm-password')),
      'fixture-password',
    );
    await _tap(tester, find.text(l10n.actionBack));
    expect(find.byType(SegmentedButton<String>), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('mnemonic-word-0')),
      -180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(_word(tester, 0).controller!.text, 'abandon');
    expect(_word(tester, 11).controller!.text, 'about');
    await _tap(tester, find.byKey(const Key('mnemonic-confirm-words')));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('mnemonic-password')))
          .controller!
          .text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmed password imports directly without email or MPC', (
    tester,
  ) async {
    final backend = _Backend();
    final l10n = await _pump(tester, backend: backend);
    await _toPassword(tester);
    await tester.enterText(
      find.byKey(const Key('mnemonic-password')),
      'fixture-password',
    );
    await tester.enterText(
      find.byKey(const Key('mnemonic-confirm-password')),
      'different-password',
    );
    await _tap(tester, find.byKey(const Key('mnemonic-confirm-password-step')));
    expect(find.text(l10n.errPasswordsMismatch), findsOneWidget);
    expect(backend.imports, 0);
    await tester.enterText(
      find.byKey(const Key('mnemonic-confirm-password')),
      'fixture-password',
    );
    await _tap(tester, find.byKey(const Key('mnemonic-confirm-password-step')));
    expect(find.text(l10n.mnemonicDoneTitle), findsOneWidget);
    expect(find.text(l10n.mnemonicVerifyIdHint), findsNothing);
    expect(find.text(l10n.labelEmail), findsNothing);
    expect(find.text(l10n.labelVerificationCode), findsNothing);
    expect(backend.imports, 1);
    expect(backend.importedPhrase, _phrase);
    expect(backend.importedGroup!.wallets.map((w) => w.curve), [
      'ed25519',
      'secp256k1',
    ]);
    expect(backend.importedGroup!.chains, hasLength(6));
    expect(backend.hasWallet, isTrue);
    expect(backend.activeWallet, 'fixture-ed25519');
    expect(find.textContaining('master-key'), findsNothing);
    expect(find.byKey(const Key('mnemonic-password')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'activation failure can be retried without importing the seed twice',
    (tester) async {
      final backend = _Backend();
      final wallet = _Wallet(backend)..activationWorks = false;
      final l10n = await _pump(tester, service: wallet, inRoute: true);
      await _toPassword(tester);
      await tester.enterText(
        find.byKey(const Key('mnemonic-password')),
        'fixture-password',
      );
      await tester.enterText(
        find.byKey(const Key('mnemonic-confirm-password')),
        'fixture-password',
      );
      await _tap(
        tester,
        find.byKey(const Key('mnemonic-confirm-password-step')),
      );
      expect(find.byKey(const Key('mnemonic-done-title')), findsOneWidget);
      expect(find.text(l10n.mnemonicOpenFailed), findsOneWidget);
      expect(find.text(l10n.mnemonicStartOver), findsNothing);
      expect(backend.imports, 1);
      expect(wallet.activations, 1);
      expect(backend.hasWallet, isFalse);
      wallet.activationWorks = true;
      await _tap(tester, find.byKey(const Key('mnemonic-open-wallet')));
      expect(find.text('Open importer'), findsOneWidget);
      expect(backend.imports, 1);
      expect(wallet.activations, 2);
      expect(wallet.selected!.isSolana, isTrue);
      expect(wallet.selected!.walletId, 'fixture-ed25519');
      expect(backend.hasWallet, isTrue);
    },
  );

  testWidgets(
    'successful import activates before Done and does not activate twice',
    (tester) async {
      final backend = _Backend();
      final wallet = _Wallet(backend);
      await _pump(tester, service: wallet, inRoute: true);
      await _toPassword(tester);
      await tester.enterText(
        find.byKey(const Key('mnemonic-password')),
        'fixture-password',
      );
      await tester.enterText(
        find.byKey(const Key('mnemonic-confirm-password')),
        'fixture-password',
      );
      await _tap(
        tester,
        find.byKey(const Key('mnemonic-confirm-password-step')),
      );
      expect(backend.hasWallet, isTrue);
      expect(wallet.activations, 1);
      await _tap(tester, find.byKey(const Key('mnemonic-open-wallet')));
      expect(find.text('Open importer'), findsOneWidget);
      expect(wallet.activations, 1);
      expect(backend.imports, 1);
    },
  );

  testWidgets(
    'failed direct import can be retried without a verification step',
    (tester) async {
      final backend = _Backend()..fail = true;
      final l10n = await _pump(tester, backend: backend);
      await _toPassword(tester);
      await tester.enterText(
        find.byKey(const Key('mnemonic-password')),
        'fixture-password',
      );
      await tester.enterText(
        find.byKey(const Key('mnemonic-confirm-password')),
        'fixture-password',
      );
      await _tap(
        tester,
        find.byKey(const Key('mnemonic-confirm-password-step')),
      );
      expect(find.text(l10n.mnemonicImportFailed), findsOneWidget);
      expect(find.text('offline import failure'), findsNothing);
      backend.fail = false;
      await _tap(tester, find.text(l10n.mnemonicStartOver));
      await _tap(tester, find.byKey(const Key('mnemonic-confirm-words')));
      await _tap(
        tester,
        find.byKey(const Key('mnemonic-confirm-password-step')),
      );
      expect(find.text(l10n.mnemonicDoneTitle), findsOneWidget);
      expect(backend.imports, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
