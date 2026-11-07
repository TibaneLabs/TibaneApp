@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/logical_wallet.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet/wallet_group_store.dart';
import 'package:tibaneapp/screens/wallet/widgets/account_switcher_view_model.dart';

const _password = 'offline-fixture-password';
const _publicPhrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

class _Transport implements Transport {
  _Transport(this.inner);
  final Transport inner;
  bool failSecondCurve = false;
  bool failBitcoinAccount = false;
  bool failDeletion = false;
  Future<void> Function()? beforeFailure;
  Completer<void>? importGate;
  Completer<void>? importArrived;
  final importedIds = <String>[];

  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    if (path == 'Wallet:importMnemonic') {
      if (importGate != null) {
        final gate = importGate!;
        importGate = null;
        importArrived!.complete();
        await gate.future;
      }
      if (failSecondCurve && params!['Curve'] == 'secp256k1') {
        await beforeFailure?.call();
        throw StateError('fixture second-curve failure');
      }
    }
    if (failBitcoinAccount &&
        path == 'Account' &&
        verb == 'POST' &&
        params!['Type'] == 'bitcoin') {
      await beforeFailure?.call();
      throw StateError('fixture account failure');
    }
    if (failDeletion && path.startsWith('Wallet/') && verb == 'DELETE') {
      throw StateError('fixture deletion failure');
    }
    final result = await inner.request(path, verb, params);
    if (path == 'Wallet:importMnemonic') {
      importedIds.add((result as Map)['Id'] as String);
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  _Client(Transport transport)
    : wallets = WalletApi(transport),
      accounts = AccountApi(transport),
      networks = NetworkApi(transport),
      storeKeys = StoreKeyApi(transport);
  @override
  final WalletApi wallets;
  @override
  final AccountApi accounts;
  @override
  final NetworkApi networks;
  @override
  final StoreKeyApi storeKeys;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(this.fixture);
  final LibwalletClient fixture;
  String fixtureContext = 'initial';
  @override
  String get signingContext => fixtureContext;
  @override
  Future<LibwalletClient> ensureClient() async => fixture;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DynamicLibrary library;
  late FfiTransport native;
  late _Transport transport;
  late _Client client;
  late _Backend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'tibane-multichain-seed-',
    );
    final binary =
        Directory(
          '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
        ).listSync().whereType<File>().singleWhere(
          (file) => file.path.endsWith('.dylib'),
        );
    library = DynamicLibrary.open(binary.path);
    native = FfiTransport.initialize(
      '${directory.path}/source',
      library: library,
    );
    transport = _Transport(native);
    client = _Client(transport);
    backend = _Backend(client);
    for (final network in await client.networks.list()) {
      await client.networks.update(network.id, rpc: 'http://127.0.0.1:9');
    }
  });

  tearDown(() async {
    backend.dispose();
    native.dispose();
    await directory.delete(recursive: true);
  });

  Future<LogicalWallet> import({
    String mnemonic = _publicPhrase,
    String passphrase = '',
  }) => backend.importMultichainMnemonicWallet(
    mnemonic: mnemonic,
    passphrase: passphrase,
    name: 'Offline fixture',
    password: _password,
  );

  Future<List<UnifiedAccount>> contexts(
    LibwalletClient sdk,
    LogicalWallet group,
  ) async {
    final accounts = (await sdk.accounts.list())
        .where((a) => group.containsWallet(a.wallet))
        .toList();
    final bitcoin = accounts.singleWhere(
      (a) => a.type == 'bitcoin' && a.index == 0,
    );
    final networks = bitcoinContextsFromNetworks(await sdk.networks.list());
    expect(networks, hasLength(4));
    final addresses = <String, String>{};
    for (final network in networks) {
      final formats = await sdk.accounts.addressFormats(
        bitcoin.id,
        network: network.networkId!,
      );
      addresses[bitcoinContextId(network.chain, bitcoin.id)] = formats.formats
          .firstWhere((f) => f.isDefault)
          .address;
    }
    return buildUnifiedAccounts(
      inappAccounts: accounts,
      walletsById: {for (final wallet in group.wallets) wallet.id: wallet},
      bitcoinAddressesByContextId: addresses,
      bitcoinNetworkContexts: networks,
    );
  }

  for (final extraPassword in ['', 'fixture-extra-password']) {
    test(
      'one phrase restores six networks and derived accounts (extra password: ${extraPassword.isNotEmpty})',
      () async {
        final phrase = await backend.generateRecoveryPhrase();
        expect(phrase.split(' '), hasLength(12));
        final group = await import(mnemonic: phrase, passphrase: extraPassword);
        expect(group.wallets.map((w) => w.curve), ['ed25519', 'secp256k1']);
        expect(
          group.wallets.every(
            (w) =>
                w.protocol == 'mnemonic' &&
                w.threshold == 0 &&
                w.keys.length == 1 &&
                w.keys.single.isPassword,
          ),
          isTrue,
        );
        expect((await client.accounts.list()).map((a) => a.type).toSet(), {
          'solana',
          'ethereum',
          'bitcoin',
        });
        final groups = await WalletGroupStore.read();
        expect(groups.values.toSet(), hasLength(1));
        expect(
          buildLogicalWallets(
            await client.wallets.list(),
            walletGroups: groups,
          ),
          hasLength(1),
        );
        final accounts = await contexts(client, group);
        expect(accounts.map((a) => a.chain).toSet(), group.chains.toSet());
        expect(
          accounts.every((a) => a.address.isNotEmpty && a.isMainWalletContext),
          isTrue,
        );
        final sidebar = buildAccountGroups(
          accounts: accounts,
          wallets: group.wallets,
          unnamedLabel: 'Unnamed',
          walletGroups: groups,
        );
        expect(sidebar, hasLength(1));
        expect(sidebar.single.mainAccounts.map((a) => a.chain), group.chains);
        expect(sidebar.single.additionalAccounts, isEmpty);
        expect(accounts.map((a) => a.address).toSet(), hasLength(6));
        for (final member in group.wallets) {
          expect(walletContentsKind(member), WalletContentsKind.native);
          expect(
            LibwalletBackend.defaultAccountTypesForWallet(member),
            member.curve == 'ed25519' ? ['solana'] : ['ethereum', 'bitcoin'],
          );
        }
        final secret = await backend.exportRecoveryPhraseGroup(
          walletIds: group.wallets.map((w) => w.id).toSet(),
          password: _password,
        );
        expect(secret.mnemonic, phrase);
        expect(secret.passphrase ?? '', extraPassword);
        await expectLater(
          backend.exportRecoveryPhraseGroup(
            walletIds: group.wallets.map((w) => w.id).toSet(),
            password: 'incorrect',
          ),
          throwsA(anything),
        );

        final derived = <String, String>{};
        for (final type in ['solana', 'ethereum']) {
          final wallet = group.walletForChain(type)!;
          final keys = [
            SigningKey(
              id: wallet.keys.single.id,
              type: 'Password',
              key: _password,
            ),
          ];
          final account = (await backend.createAccount(
            walletId: wallet.id,
            name: 'Account 2',
            type: type,
            keys: keys,
          ))!;
          expect(account.index, 1);
          final signature = await client.accounts.signMessage(
            account.id,
            mode: type == 'solana' ? 'solana' : 'evm',
            message: Uint8List.fromList('Offline fixture only'.codeUnits),
            keys: keys.map((k) => k.toJson()).toList(),
          );
          expect(signature.signature, isNotEmpty);
          derived[type] = account.address;
        }
        final withDerived = await contexts(client, group);
        expect(withDerived.where((a) => a.isMainWalletContext), hasLength(6));
        expect(withDerived.where((a) => !a.isMainWalletContext), hasLength(2));

        final restoredNative = FfiTransport.initialize(
          '${directory.path}/restored',
          library: library,
        );
        final restored = _Client(restoredNative);
        final restoredBackend = _Backend(restored);
        addTearDown(() {
          restoredBackend.dispose();
          restoredNative.dispose();
        });
        final reopened = await restoredBackend.importMultichainMnemonicWallet(
          mnemonic: phrase,
          passphrase: extraPassword,
          name: 'Restored fixture',
          password: 'different-fixture-password',
        );
        final restoredAccounts = await contexts(restored, reopened);
        expect(
          {for (final a in restoredAccounts) a.chain: a.address},
          {for (final a in accounts) a.chain: a.address},
        );
        for (final type in derived.keys) {
          final wallet = reopened.walletForChain(type)!;
          final account = (await restoredBackend.createAccount(
            walletId: wallet.id,
            name: 'Account 2',
            type: type,
            keys: [
              SigningKey(
                id: wallet.keys.single.id,
                type: 'Password',
                key: 'different-fixture-password',
              ),
            ],
          ))!;
          expect(account.address, derived[type]);
        }
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getKeys().map(prefs.get).join(), isNot(contains(phrase)));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test('24-word imports also open all six networks', () async {
    final phrase = await backend.generateRecoveryPhrase(words: 24);
    final group = await import(mnemonic: phrase);
    expect(await contexts(client, group), hasLength(6));
    final secret = await backend.exportRecoveryPhraseGroup(
      walletIds: group.wallets.map((w) => w.id).toSet(),
      password: _password,
    );
    expect(secret.mnemonic, phrase);
  });

  test(
    'context changes during import leave no new wallets or orphan accounts',
    () async {
      final gate = Completer<void>();
      transport.importGate = gate;
      transport.importArrived = Completer<void>();
      final pending = import();
      final result = expectLater(pending, throwsStateError);
      await transport.importArrived!.future;
      backend.fixtureContext = 'changed';
      gate.complete();
      await result;
      expect(await client.wallets.list(), isEmpty);
      expect(await client.accounts.list(), isEmpty);
      expect(await WalletGroupStore.read(), isEmpty);
    },
  );

  test(
    'failed first import leaves an empty store clean and can be retried',
    () async {
      transport.failSecondCurve = true;
      await expectLater(import(), throwsStateError);
      expect(await client.wallets.list(), isEmpty);
      expect(await client.accounts.list(), isEmpty);
      transport.failSecondCurve = false;
      expect((await import()).wallets, hasLength(2));
    },
  );

  for (final failAt in ['second curve', 'bitcoin account']) {
    test(
      '$failAt failure rolls back only owned wallets and preserves current account',
      () async {
        final existingPhrase = await backend.generateRecoveryPhrase();
        final old = await backend.importMnemonicWallet(
          mnemonic: existingPhrase,
          passphrase: '',
          curve: 'ed25519',
          name: 'Existing fixture',
          password: _password,
        );
        final oldAccount = (await client.accounts.list()).single;
        await client.accounts.setCurrent(oldAccount.id);
        await WalletGroupStore.associate([old.id]);
        final groupsBefore = await WalletGroupStore.read();
        transport.failSecondCurve = failAt == 'second curve';
        transport.failBitcoinAccount = failAt == 'bitcoin account';
        Wallet? concurrent;
        transport.beforeFailure = () async {
          // A separately created wallet must not be treated as an import side effect.
          concurrent = await client.wallets.importMnemonic(
            mnemonic: await backend.generateRecoveryPhrase(),
            curve: 'ed25519',
            name: 'Unrelated fixture',
            keys: [KeyDescription.password(_password)],
          );
        };
        await expectLater(import(), throwsStateError);
        expect((await client.wallets.list()).map((w) => w.id).toSet(), {
          old.id,
          concurrent!.id,
        });
        expect((await client.accounts.list()).map((a) => a.id), [
          oldAccount.id,
        ]);
        expect((await client.accounts.getCurrent()).id, oldAccount.id);
        expect(await WalletGroupStore.read(), groupsBefore);
      },
    );
  }

  test(
    'second-curve duplicate rolls back new Solana member without deleting the existing wallet',
    () async {
      final old = await backend.importMnemonicWallet(
        mnemonic: _publicPhrase,
        passphrase: '',
        curve: 'secp256k1',
        name: 'Already imported fixture',
        password: _password,
      );
      final oldAccounts = (await client.accounts.list())
          .map((a) => a.id)
          .toSet();
      await expectLater(
        import(),
        throwsA(isA<PrivateKeyAccountExistsException>()),
      );
      expect((await client.wallets.list()).map((w) => w.id), [old.id]);
      expect(
        (await client.accounts.list()).map((a) => a.id).toSet(),
        oldAccounts,
      );
      expect(await WalletGroupStore.read(), isEmpty);
    },
  );

  test(
    'incomplete rollback is surfaced and the import guard is released',
    () async {
      transport.failSecondCurve = true;
      transport.failDeletion = true;
      await expectLater(
        import(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'cleanup warning',
            'mnemonic_rollback_incomplete',
          ),
        ),
      );
      expect(await client.wallets.list(), hasLength(1));
      transport.failDeletion = false;
      transport.failSecondCurve = false;
      final next = await import(
        mnemonic: await backend.generateRecoveryPhrase(),
      );
      expect(next.wallets, hasLength(2));
    },
  );

  test(
    'concurrent imports are rejected before a second import can start',
    () async {
      final gate = Completer<void>();
      transport.importGate = gate;
      transport.importArrived = Completer<void>();
      final pending = import();
      await transport.importArrived!.future;
      await expectLater(import(), throwsStateError);
      expect(
        () => backend.importMnemonicWallet(
          mnemonic: _publicPhrase,
          passphrase: '',
          curve: 'ed25519',
          name: 'Blocked',
          password: _password,
        ),
        throwsStateError,
      );
      gate.complete();
      expect((await pending).wallets, hasLength(2));
    },
  );
}
