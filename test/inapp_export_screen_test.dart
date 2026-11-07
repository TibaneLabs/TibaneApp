import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/inapp_export_screen.dart';
import 'package:tibaneapp/services/wallet/accounts_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/mwa_wallet_backend.dart';
import 'package:tibaneapp/services/wallet/wallet_export_format.dart';
import 'package:tibaneapp/services/wallet/wallet_group_store.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/utils/wallet_error.dart';

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

Wallet _seedWallet(String id, {String curve = 'ed25519'}) => Wallet(
  id: id,
  name: 'Seed wallet',
  curve: curve,
  protocol: 'mnemonic',
  threshold: 0,
  gen: 0,
  pubkey: 'public-$id',
  chaincode: '',
  created: DateTime.utc(2026),
  modified: DateTime.utc(2026),
  keys: [
    WalletKey(
      id: 'password-$id',
      wallet: id,
      type: 'Password',
      key: 'password-public-$id',
      gen: 0,
    ),
  ],
);

Wallet _wallet(String id, {bool imported = false, String curve = 'ed25519'}) =>
    Wallet(
      id: id,
      name: id == 'other' ? 'Other wallet' : 'Main wallet',
      curve: curve,
      threshold: imported ? 0 : 1,
      gen: 0,
      pubkey: 'public-$id',
      chaincode: '',
      created: DateTime.utc(2026),
      modified: DateTime.utc(2026),
      keys: [
        WalletKey(
          id: 'store-$id',
          wallet: id,
          type: 'StoreKey',
          key: 'device-public-$id',
          gen: 0,
        ),
        if (!imported)
          WalletKey(
            id: 'password-$id',
            wallet: id,
            type: 'Password',
            key: 'password-public-$id',
            gen: 0,
          ),
      ],
    );

class _Transport implements Transport {
  List<Wallet> wallets = [
    _wallet('native-sol'),
    _wallet('native-eth', curve: 'secp256k1'),
    _wallet('imported', imported: true),
    _wallet('other'),
  ];
  final backups = <String>[];
  final verified = <String>[];
  bool failList = false;
  final secretRequests = <String>[];
  Completer<void>? secretGate;
  Object? secretError;
  String passphrase = '';
  final phrasesByWallet = <String, String>{};

  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    if (path == 'Wallet' && verb == 'GET') {
      if (failList) throw StateError('Network unavailable');
      return wallets.map((wallet) => wallet.toJson()).toList();
    }
    for (final wallet in wallets) {
      if (path == 'Wallet/${wallet.id}' && verb == 'GET') {
        return wallet.toJson();
      }
      if (path == 'Wallet/${wallet.id}:backup' && verb == 'GET') {
        backups.add(wallet.id);
        return [
          {'filename': '${wallet.id}.dat', 'data': 'encrypted-${wallet.id}'},
        ];
      }
      if (path == 'Wallet/${wallet.id}:exportSecret' && verb == 'POST') {
        secretRequests.add(wallet.id);
        await secretGate?.future;
        if (secretError != null) throw secretError!;
        return {
          'type': 'mnemonic',
          'curve': wallet.curve,
          'mnemonic': phrasesByWallet[wallet.id] ?? _phrase,
          'passphrase': passphrase,
          'language': 'english',
        };
      }
    }
    if (path == 'StoreKey:derivePassword') {
      final keyId = params!['WalletKeyId'] as String;
      verified.add(keyId);
      final id = keyId.substring('password-'.length);
      return {
        'Public_Key': params['Password'] == 'correct-password'
            ? 'password-public-$id'
            : 'incorrect-public',
      };
    }
    throw StateError('Unexpected request $verb $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  _Client(Transport transport)
    : wallets = WalletApi(transport),
      storeKeys = StoreKeyApi(transport);
  @override
  final WalletApi wallets;
  @override
  final StoreKeyApi storeKeys;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(this.transport) : client = _Client(transport);
  final _Transport transport;
  final _Client client;
  @override
  String get walletId => 'imported';
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

class _Accounts extends AccountsService {
  _Accounts(LibwalletBackend backend) : super(backend, MwaWalletBackend());
  @override
  Map<String, String> get attachedWalletParents => {'imported': 'native-sol'};
  @override
  Map<String, String> get walletGroups => {
    'native-sol': 'native-sol',
    'native-eth': 'native-sol',
    'seed-sol': 'seed-sol',
    'seed-eth': 'seed-sol',
  };
}

class _Service extends WalletService {
  _Service(this.backend) : store = _Accounts(backend);
  final _Backend backend;
  final _Accounts store;
  @override
  LibwalletBackend get libwallet => backend;
  @override
  AccountsService get accountsService => store;
  @override
  void dispose() {
    store.dispose();
    backend.dispose();
    super.dispose();
  }
}

Future<AppLocalizations> _pump(
  WidgetTester tester,
  _Transport transport, {
  String language = 'en',
  Set<String>? walletIds,
  bool showNext = false,
  Size size = const Size(375, 667),
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final service = _Service(_Backend(transport));
  addTearDown(service.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: service,
      child: MaterialApp(
        locale: Locale(language),
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: InAppExportScreen(walletIds: walletIds, showNext: showNext),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byType(InAppExportScreen)));
}

Future<void> _revealSeed(
  WidgetTester tester,
  AppLocalizations l10n, {
  String password = 'correct-password',
  bool wait = true,
}) async {
  await tester.ensureVisible(find.byKey(const Key('seed-export-agree')));
  await tester.tap(find.byKey(const Key('seed-export-agree')));
  await tester.enterText(find.byType(TextField), password);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(l10n.exportShowSeedButton));
  await tester.tap(find.text(l10n.exportShowSeedButton));
  if (wait) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _export(
  WidgetTester tester,
  AppLocalizations l10n, {
  String password = 'correct-password',
}) async {
  await tester.enterText(find.byType(TextField), password);
  final button = find.text(l10n.exportShowBackupButton);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'one multichain seed wallet authenticates both members and exports one phrase',
    (tester) async {
      final transport = _Transport()
        ..wallets = [
          _seedWallet('seed-sol'),
          _seedWallet('seed-eth', curve: 'secp256k1'),
        ];
      await WalletGroupStore.associate(['seed-sol', 'seed-eth']);
      final l10n = await _pump(tester, transport);
      expect(find.text('Seed wallet'), findsOneWidget);
      await _revealSeed(tester, l10n);
      expect(transport.secretRequests.toSet(), {'seed-sol', 'seed-eth'});
      expect(transport.verified.toSet(), {
        'password-seed-sol',
        'password-seed-eth',
      });
      expect(transport.backups, isEmpty);
      expect(find.byKey(const Key('exported-recovery-word-0')), findsOneWidget);
      expect(
        find.byKey(const Key('exported-recovery-word-11')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('inconsistent seed group never reveals either phrase', (
    tester,
  ) async {
    final transport = _Transport()
      ..wallets = [
        _seedWallet('seed-sol'),
        _seedWallet('seed-eth', curve: 'secp256k1'),
      ];
    transport.phrasesByWallet['seed-eth'] =
        'legal winner thank year wave sausage worth useful legal winner thank yellow';
    await WalletGroupStore.associate(['seed-sol', 'seed-eth']);
    final l10n = await _pump(tester, transport);
    await _revealSeed(tester, l10n);
    expect(transport.secretRequests, hasLength(2));
    expect(find.byKey(const Key('exported-recovery-word-0')), findsNothing);
    expect(find.byKey(const Key('seed-export-copy')), findsNothing);
    expect(transport.backups, isEmpty);
  });

  testWidgets(
    'same-name seeds without an explicit relationship stay separate',
    (tester) async {
      final transport = _Transport()
        ..wallets = [
          _seedWallet('seed-a'),
          _seedWallet('seed-b', curve: 'secp256k1'),
        ];
      final l10n = await _pump(tester, transport);
      await _revealSeed(tester, l10n);
      expect(transport.secretRequests, ['seed-a']);
      expect(transport.backups, isEmpty);
    },
  );

  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final size in [const Size(320, 667), const Size(393, 852)]) {
      testWidgets(
        'seed export reveals words without a JSON file in $language at $size',
        (tester) async {
          final transport = _Transport()..wallets = [_seedWallet('seed')];
          final l10n = await _pump(
            tester,
            transport,
            language: language,
            size: size,
            walletIds: {'seed'},
            showNext: true,
          );
          expect(find.text(l10n.exportBackupScopeNotice), findsNothing);
          expect(find.text(l10n.actionNext), findsNothing);
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, l10n.exportShowSeedButton),
                )
                .onPressed,
            isNull,
          );
          expect(transport.secretRequests, isEmpty);
          await _revealSeed(tester, l10n);
          expect(transport.secretRequests, ['seed']);
          expect(transport.backups, isEmpty);
          expect(
            find.byKey(const Key('exported-recovery-word-0')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('exported-recovery-word-11')),
            findsOneWidget,
          );
          expect(find.text(l10n.exportShareButton), findsNothing);
          expect(find.byType(SelectableText), findsNothing);
          expect(find.text(l10n.actionNext), findsOneWidget);
          final hide = find.byKey(const Key('seed-export-hide'));
          await tester.scrollUntilVisible(
            hide,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(hide);
          await tester.pumpAndSettle();
          await tester.tap(hide);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('exported-recovery-word-0')),
            findsNothing,
          );
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            '',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('imported active account exports native wallet in $language', (
      tester,
    ) async {
      final transport = _Transport();
      final l10n = await _pump(tester, transport, language: language);
      expect(find.text('Main wallet'), findsOneWidget);
      expect(find.text(l10n.exportBackupScopeNotice), findsOneWidget);
      await _export(tester, l10n);
      expect(transport.backups, ['native-sol', 'native-eth']);
      expect(transport.verified.toSet(), {
        'password-native-sol',
        'password-native-eth',
      });
      final json = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .data!;
      expect((jsonDecode(json) as List).length, 2);
      expect(json, isNot(contains('encrypted-imported')));
      expect(json, isNot(contains('encrypted-other')));
      expect(find.text(l10n.exportShareButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('imported-only device gives export guidance in $language', (
      tester,
    ) async {
      final transport = _Transport()
        ..wallets = [_wallet('imported', imported: true)];
      final l10n = await _pump(tester, transport, language: language);
      expect(find.text(l10n.exportPrivateKeyAccount), findsOneWidget);
      expect(
        WalletError.from(
          StateError('private_key_wallet_backup_unavailable'),
        ).localizedMessage(l10n),
        l10n.exportPrivateKeyAccount,
      );
      expect(find.byType(TextField), findsNothing);
      expect(transport.backups, isEmpty);
      expect(transport.verified, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('wrong password never reveals or exports a backup', (
    tester,
  ) async {
    final transport = _Transport();
    final l10n = await _pump(tester, transport);
    await _export(tester, l10n, password: 'wrong-password');
    expect(find.text(l10n.walletErrorIncorrectPassword), findsOneWidget);
    expect(transport.backups, isEmpty);
    expect(find.byType(SelectableText), findsNothing);
    await _export(tester, l10n);
    expect(transport.backups.length, 2);
  });

  testWidgets('wrong seed password never calls exportSecret or backup', (
    tester,
  ) async {
    final transport = _Transport()..wallets = [_seedWallet('seed')];
    final l10n = await _pump(tester, transport);
    await _revealSeed(tester, l10n, password: 'wrong-password');
    expect(find.text(l10n.walletErrorIncorrectPassword), findsOneWidget);
    expect(transport.secretRequests, isEmpty);
    expect(transport.backups, isEmpty);
    expect(find.byKey(const Key('seed-export-copy')), findsNothing);
  });

  testWidgets('a seed wallet restored from a backup exports JSON', (
    tester,
  ) async {
    final transport = _Transport()..wallets = [_seedWallet('seed')];
    await WalletExportPolicy.recordBackupImports({'seed'});
    final l10n = await _pump(tester, transport);
    expect(find.byKey(const Key('seed-export-agree')), findsNothing);
    await _export(tester, l10n);
    expect(transport.backups, ['seed']);
    expect(transport.secretRequests, isEmpty);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('changing wallets changes format and resets seed agreement', (
    tester,
  ) async {
    final transport = _Transport()
      ..wallets = [_seedWallet('seed'), _wallet('other')];
    final l10n = await _pump(tester, transport);
    await tester.tap(find.byKey(const Key('seed-export-agree')));
    await tester.enterText(find.byType(TextField), 'correct-password');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('wallet-selector-trigger')),
    );
    await tester.tap(find.byKey(const Key('wallet-selector-trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other wallet'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.exportShowBackupButton), findsOneWidget);
    expect(find.byKey(const Key('seed-export-agree')), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    await _export(tester, l10n);
    expect(transport.backups, ['other']);
    expect(transport.secretRequests, isEmpty);
  });

  testWidgets('seed errors never render raw native secrets', (tester) async {
    final transport = _Transport()
      ..wallets = [_seedWallet('seed')]
      ..secretError = StateError('native error containing $_phrase');
    final l10n = await _pump(tester, transport);
    await _revealSeed(tester, l10n);
    expect(find.text(l10n.exportSeedFailed), findsOneWidget);
    expect(find.textContaining(_phrase), findsNothing);
    expect(transport.backups, isEmpty);
  });

  testWidgets('seed and optional extra password copy separately', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final transport = _Transport()
      ..wallets = [_seedWallet('seed')]
      ..passphrase = 'public extra recovery password';
    final l10n = await _pump(tester, transport);
    await _revealSeed(tester, l10n);
    for (final key in ['seed-export-copy', 'seed-passphrase-copy']) {
      await tester.scrollUntilVisible(
        find.byKey(Key(key)),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }
    expect(copied, [_phrase, transport.passphrase]);
    expect(find.text(l10n.exportSeedPassphraseHint), findsOneWidget);
  });

  for (final inFlight in [false, true]) {
    testWidgets(
      'background hides seed and cancels reveal (inFlight=$inFlight)',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        final transport = _Transport()..wallets = [_seedWallet('seed')];
        if (inFlight) transport.secretGate = Completer<void>();
        final l10n = await _pump(tester, transport);
        await _revealSeed(tester, l10n, wait: !inFlight);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        transport.secretGate?.complete();
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('exported-recovery-word-0')), findsNothing);
        expect(find.byKey(const Key('seed-export-copy')), findsNothing);
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const Key('seed-export-agree')),
              )
              .value,
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('wallet selection clears password and exports only that wallet', (
    tester,
  ) async {
    final transport = _Transport();
    final l10n = await _pump(tester, transport);
    await tester.enterText(find.byType(TextField), 'correct-password');
    await tester.ensureVisible(
      find.byKey(const Key('wallet-selector-trigger')),
    );
    await tester.tap(find.byKey(const Key('wallet-selector-trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other wallet'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    await _export(tester, l10n);
    expect(transport.backups, ['other']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit export selection never falls back to active account', (
    tester,
  ) async {
    final transport = _Transport();
    final l10n = await _pump(
      tester,
      transport,
      walletIds: {'other'},
      showNext: true,
    );
    expect(find.text(l10n.actionNext), findsNothing);
    await _export(tester, l10n);
    expect(transport.backups, ['other']);
    expect(find.text(l10n.actionNext), findsOneWidget);
  });

  testWidgets('load failure can retry without changing the active account', (
    tester,
  ) async {
    final transport = _Transport()..failList = true;
    final l10n = await _pump(tester, transport);
    expect(find.byType(TextField), findsNothing);
    transport.failList = false;
    await tester.tap(find.text(l10n.mnemonicStartOver));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(transport.backups, isEmpty);
  });

  test(
    'MPC recovery phrase export is rejected before authentication or disclosure',
    () async {
      final transport = _Transport();
      final backend = _Backend(transport);
      addTearDown(backend.dispose);
      await expectLater(
        backend.exportRecoveryPhrase(
          walletId: 'native-sol',
          password: 'correct-password',
        ),
        throwsStateError,
      );
      expect(transport.verified, isEmpty);
      expect(transport.secretRequests, isEmpty);
      expect(transport.backups, isEmpty);
    },
  );

  test(
    'a wallet changed during export never returns its recovery words',
    () async {
      final transport = _Transport()
        ..wallets = [_seedWallet('seed')]
        ..secretGate = Completer<void>();
      final backend = _Backend(transport);
      addTearDown(backend.dispose);
      final result = expectLater(
        backend.exportRecoveryPhrase(
          walletId: 'seed',
          password: 'correct-password',
        ),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(transport.secretRequests, ['seed']);
      transport.wallets = [_wallet('seed')];
      transport.secretGate!.complete();
      await result;
    },
  );

  test(
    'direct imported-account backup remains blocked, with a clear reason',
    () async {
      final transport = _Transport();
      final backend = _Backend(transport);
      addTearDown(backend.dispose);
      try {
        await backend.exportBackupJson(
          'correct-password',
          walletIds: {'imported'},
        );
        fail('A single-key account is not a password-protected wallet backup');
      } catch (error) {
        expect(
          WalletError.from(error).key,
          WalletErrorKey.privateKeyWalletBackup,
        );
      }
      expect(transport.verified, isEmpty);
      expect(transport.backups, isEmpty);
    },
  );
}
