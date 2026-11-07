@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

const _solanaSeed =
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';
const _ethereumScalar =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Transport implements Transport {
  _Transport(this.inner);
  final Transport inner;
  final calls = <String>[];
  String? hidePublicKey;
  Map<String, dynamic>? reuseWallet;
  Completer<void>? gate;
  Completer<void>? arrived;
  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    calls.add('$verb $path');
    if (path == 'Wallet' && verb == 'GET' && gate != null) {
      arrived?.complete();
      final wait = gate!;
      gate = null;
      await wait.future;
    }
    if (path == 'Wallet:importPrivateKey' && reuseWallet != null) {
      return reuseWallet;
    }
    final result = await inner.request(path, verb, params);
    if (path == 'Account' && verb == 'GET' && hidePublicKey != null) {
      return [
        for (final raw in result as List)
          if (raw['Id'] == hidePublicKey)
            {
              ...raw as Map<String, dynamic>,
              'Pubkey': '',
              'Address': (raw['Address'] as String).toLowerCase(),
            }
          else
            raw,
      ];
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
      storeKeys = StoreKeyApi(transport),
      networks = NetworkApi(transport);
  @override
  final WalletApi wallets;
  @override
  final AccountApi accounts;
  @override
  final StoreKeyApi storeKeys;
  @override
  final NetworkApi networks;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(this.fixture);
  final LibwalletClient fixture;
  @override
  Future<LibwalletClient> ensureClient() async => fixture;
  @override
  Future<void> ensureSolanaDefault({bool force = false}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late FfiTransport native;
  late _Transport transport;
  late _Client client;
  late _Backend backend;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('tibane-unique-import-');
    final binary = Directory(
      '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
    ).listSync().whereType<File>().singleWhere((f) => f.path.endsWith('.dylib'));
    native = FfiTransport.initialize(
      directory.path,
      library: DynamicLibrary.open(binary.path),
    );
    transport = _Transport(native);
    client = _Client(transport);
    backend = _Backend(client);
    final network = (await client.networks.list(
      testNet: false,
    )).firstWhere((n) => n.type == NetworkType.evm && n.chainId == '1');
    await client.networks.setCurrent(network.id);
  });
  tearDown(() async {
    backend.dispose();
    native.dispose();
    await directory.delete(recursive: true);
  });

  Future<ImportedWalletAccount> rawImport(String chain) async {
    final store = await client.storeKeys.create();
    final wallet = await client.wallets.importPrivateKey(
      privateKey: chain == 'solana' ? _solanaSeed : _ethereumScalar,
      curve: chain == 'solana' ? 'ed25519' : 'secp256k1',
      format: chain == 'solana' ? 'seed' : null,
      name: 'Existing in another wallet',
      keys: [KeyDescription.storeKey(store.publicKey)],
    );
    final account = await client.accounts.create(
      wallet: wallet.id,
      name: 'Existing account',
      type: chain,
      index: 0,
    );
    return ImportedWalletAccount(wallet: wallet, account: account);
  }

  Future<ImportedWalletAccount> appImport(
    String chain, {
    String? expectedAddress,
  }) => backend.importPrivateKey(
    privateKey: chain == 'solana' ? _solanaSeed : _ethereumScalar,
    curve: chain == 'solana' ? 'ed25519' : 'secp256k1',
    accountType: chain,
    format: chain == 'solana' ? 'seed' : null,
    walletName: 'Different selected wallet',
    accountName: 'Attempted duplicate',
    expectedAddress: expectedAddress,
  );

  for (final chain in ['solana', 'ethereum']) {
    test(
      '$chain duplicate is rejected globally without changing active account or existing records',
      () async {
        final existing = await rawImport(chain);
        final previous = await client.accounts.createView(
          type: 'solana',
          address: '11111111111111111111111111111111',
        );
        await client.accounts.setCurrent(previous.id);
        final beforeNetwork = (await client.networks.getCurrent()).id;
        final before = (await client.accounts.list()).map((a) => a.id).toSet();
        transport.calls.clear();
        await expectLater(
          appImport(
            chain,
            expectedAddress: chain == 'solana'
                ? existing.account.address
                : null,
          ),
          throwsA(
            isA<PrivateKeyAccountExistsException>().having(
              (e) => e.account.id,
              'existing account',
              existing.account.id,
            ),
          ),
        );
        expect((await client.wallets.list()).map((w) => w.id).toSet(), {
          existing.wallet.id,
        });
        expect((await client.accounts.list()).map((a) => a.id).toSet(), before);
        expect((await client.accounts.getCurrent()).id, previous.id);
        expect((await client.networks.getCurrent()).id, beforeNetwork);
        expect(backend.accountId, isNull);
        expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
        if (chain == 'solana') {
          expect(
            transport.calls,
            isNot(contains('POST Wallet:importPrivateKey')),
          );
        } else {
          expect(
            transport.calls.where((c) => c.startsWith('DELETE Wallet/')),
            hasLength(1),
          );
          expect(
            transport.calls,
            isNot(contains('DELETE Wallet/${existing.wallet.id}')),
          );
          expect(transport.calls, isNot(contains('POST Account')));
        }
      },
    );

    test(
      '$chain unique import remains available and is blocked on the next attempt',
      () async {
        final first = await appImport(chain);
        expect(first.account.name, 'Attempted duplicate');
        expect(first.wallet.threshold, 0);
        expect(backend.accountId, first.account.id);
        await expectLater(
          appImport(chain),
          throwsA(isA<PrivateKeyAccountExistsException>()),
        );
        expect((await client.wallets.list()).map((w) => w.id).toSet(), {
          first.wallet.id,
        });
        expect((await client.accounts.getCurrent()).id, first.account.id);
      },
    );
  }

  test(
    'address fallback handles legacy missing public keys and Ethereum address casing',
    () async {
      final existing = await rawImport('ethereum');
      final previous = await client.accounts.createView(
        type: 'solana',
        address: '11111111111111111111111111111111',
      );
      await client.accounts.setCurrent(previous.id);
      final beforeNetwork = (await client.networks.getCurrent()).id;
      transport.hidePublicKey = existing.account.id;
      transport.calls.clear();
      await expectLater(
        appImport('ethereum'),
        throwsA(
          isA<PrivateKeyAccountExistsException>().having(
            (e) => e.account.id,
            'existing',
            existing.account.id,
          ),
        ),
      );
      expect(transport.calls, contains('POST Account'));
      expect((await client.wallets.list()).map((w) => w.id).toSet(), {
        existing.wallet.id,
      });
      expect((await client.accounts.getCurrent()).id, previous.id);
      expect((await client.networks.getCurrent()).id, beforeNetwork);
      expect((await client.accounts.list()).map((a) => a.id).toSet(), {
        existing.account.id,
        previous.id,
      });
    },
  );

  test(
    'a wallet returned by future SDK deduplication is never deleted',
    () async {
      final existing = await rawImport('ethereum');
      transport.reuseWallet = existing.wallet.toJson();
      transport.calls.clear();
      await expectLater(
        appImport('ethereum'),
        throwsA(isA<PrivateKeyAccountExistsException>()),
      );
      expect(
        transport.calls,
        isNot(contains('DELETE Wallet/${existing.wallet.id}')),
      );
      expect((await client.wallets.list()).single.id, existing.wallet.id);
    },
  );

  test('concurrent attempts cannot create a second imported wallet', () async {
    await rawImport('ethereum');
    final release = Completer<void>();
    transport.gate = release;
    transport.arrived = Completer<void>();
    final first = expectLater(
      appImport('ethereum'),
      throwsA(isA<PrivateKeyAccountExistsException>()),
    );
    await transport.arrived!.future;
    await expectLater(appImport('ethereum'), throwsStateError);
    release.complete();
    await first;
    expect(await client.wallets.list(), hasLength(1));
  });

  test(
    'different Ethereum keys with identical labels remain separate accounts',
    () async {
      final first = await appImport('ethereum');
      final second = await backend.importPrivateKey(
        privateKey: '${_ethereumScalar.substring(0, 63)}2',
        curve: 'secp256k1',
        accountType: 'ethereum',
        walletName: first.wallet.name,
        accountName: first.account.name,
      );
      expect(second.account.address, isNot(first.account.address));
      expect((await client.wallets.list()).map((w) => w.id).toSet(), {
        first.wallet.id,
        second.wallet.id,
      });
      expect(
        (await client.accounts.get(first.account.id)).address,
        first.account.address,
      );
      expect(backend.accountId, second.account.id);
    },
  );
}
