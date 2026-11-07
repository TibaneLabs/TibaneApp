@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/logical_wallet.dart';
import 'package:tibaneapp/services/wallet/mwa_wallet_backend.dart';
import 'package:tibaneapp/services/wallet_service.dart';

// Public BIP-39 vector, stored only in isolated temporary SDK databases.
const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _password = 'offline-activation-password';

class _Backend extends LibwalletBackend {
  _Backend(LibwalletClient client) : super(client: client);
  bool failActivation = false;

  @override
  Future<SwitchResult> switchWallet(String walletId, {String? password}) =>
      failActivation
      ? Future.value(SwitchResult.error)
      : super.switchWallet(walletId, password: password);
}

class _Service extends WalletService {
  _Service(_Backend backend, MwaWalletBackend mwa)
    : super(libwalletBackend: backend, mwaBackend: mwa);

  // Activation must not depend on balances, prices, or a live RPC provider.
  @override
  Future<void> refreshBalances() async {}
}

class _Fixture {
  _Fixture(this.client) : backend = _Backend(client), mwa = MwaWalletBackend() {
    service = _Service(backend, mwa);
  }

  final LibwalletClient client;
  final _Backend backend;
  final MwaWalletBackend mwa;
  late final _Service service;
  bool _closed = false;

  static Future<_Fixture> open(String path, DynamicLibrary library) async {
    final client = LibwalletClient.initialize(path, library: library);
    await client.ready;
    for (final network in await client.networks.list()) {
      await client.networks.update(network.id, rpc: 'http://127.0.0.1:9');
    }
    return _Fixture(client);
  }

  Future<LogicalWallet> import({String passphrase = ''}) =>
      backend.importMultichainMnemonicWallet(
        mnemonic: _phrase,
        passphrase: passphrase,
        name: 'Offline activation fixture',
        password: _password,
      );

  void close() {
    if (_closed) return;
    _closed = true;
    service.dispose();
    backend.dispose();
    mwa.dispose();
    client.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DynamicLibrary library;
  late _Fixture fixture;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'tibane-seed-activation-',
    );
    final binary =
        Directory(
          '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
        ).listSync().whereType<File>().singleWhere(
          (file) => file.path.endsWith('.dylib'),
        );
    library = DynamicLibrary.open(binary.path);
    fixture = await _Fixture.open(directory.path, library);
  });

  tearDown(() async {
    fixture.close();
    await directory.delete(recursive: true);
  });

  Future<void> expectActivated(LogicalWallet group) async {
    final service = fixture.service;
    final current = service.currentAccount!;
    expect(group.containsWallet(current.walletId!), isTrue);
    expect(current.isSolana && current.isMainWalletContext, isTrue);
    expect(fixture.backend.hasWallet, isTrue);
    expect(service.isConnected, isTrue);
    expect(service.kind, WalletKind.inapp);
    expect(service.publicKey, current.address);
    expect((await fixture.client.accounts.getCurrent()).id, current.accountId);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('libw_wallet_id'), current.walletId);
    expect(prefs.getString('libw_account_id'), current.accountId);
    expect(prefs.getString('current_account_id'), current.id);
    expect(prefs.getString('wallet_backend'), 'inapp');
    final settings = prefs.getKeys().map((key) => prefs.get(key)).join(' ');
    expect(settings, isNot(contains(_phrase)));
    expect(settings, isNot(contains(_password)));
  }

  test(
    'imported wallet is activated and remains selected after reopening',
    () async {
      final group = await fixture.import();
      expect(fixture.backend.hasWallet, isFalse);
      expect(await fixture.service.activateWalletGroup(group), isTrue);
      await expectActivated(group);
      final account = fixture.service.currentAccount!;
      fixture.close();
      fixture = await _Fixture.open(directory.path, library);
      await fixture.service.tryRestore();
      await expectActivated(group);
      expect(fixture.service.currentAccount!.id, account.id);
      expect(fixture.service.publicKey, account.address);
      expect(await fixture.client.wallets.list(), hasLength(2));
      expect(await fixture.client.accounts.list(), hasLength(3));
    },
  );

  test(
    'startup repairs an older import with no active wallet pointers',
    () async {
      final group = await fixture.import();
      expect(fixture.backend.hasWallet, isFalse);
      await fixture.service.tryRestore();
      await expectActivated(group);
      expect(await fixture.client.wallets.list(), hasLength(2));
      expect(await fixture.client.accounts.list(), hasLength(3));
    },
  );

  for (final chain in ['solana', 'ethereum', 'litecoin']) {
    test(
      'startup preserves the saved $chain account when activation is missing',
      () async {
        final group = await fixture.import();
        if (chain != 'litecoin') {
          final wallet = group.walletForChain(chain)!;
          final derived = await fixture.backend.createAccount(
            walletId: wallet.id,
            name: 'Derived fixture',
            type: chain,
            keys: [
              SigningKey(
                id: wallet.keys.single.id,
                type: 'Password',
                key: _password,
              ),
            ],
          );
          expect(derived?.index, 1);
        }
        await fixture.service.refreshAccounts();
        final account = fixture.service.accounts.singleWhere(
          (a) =>
              a.chain == chain &&
              (chain == 'litecoin' || !a.isMainWalletContext),
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('current_account_id', account.id);
        expect(fixture.backend.hasWallet, isFalse);
        await fixture.service.tryRestore();
        expect(fixture.service.currentAccount!.id, account.id);
        expect(fixture.service.publicKey, account.address);
        expect(fixture.backend.currentNetwork!.type, switch (chain) {
          'solana' => NetworkType.solana,
          'ethereum' => NetworkType.evm,
          _ => NetworkType.bitcoin,
        });
        if (chain == 'litecoin') {
          expect(fixture.backend.currentNetwork!.chainId, 'litecoin');
        }
        expect(fixture.backend.hasWallet, isTrue);
        expect(fixture.service.kind, WalletKind.inapp);
      },
    );
  }

  test('activating another group never selects an unrelated wallet', () async {
    final first = await fixture.import();
    expect(await fixture.service.activateWalletGroup(first), isTrue);
    final second = await fixture.import(passphrase: 'different public fixture');
    expect(
      first.containsWallet(fixture.service.currentAccount!.walletId!),
      isTrue,
    );
    expect(await fixture.service.activateWalletGroup(second), isTrue);
    await expectActivated(second);
    expect(await fixture.client.wallets.list(), hasLength(4));
  });

  test(
    'Bitcoin-family switching and restore keep the selected network address',
    () async {
      final group = await fixture.import();
      expect(await fixture.service.activateWalletGroup(group), isTrue);
      for (final chain in ['bitcoin', 'bitcoin-cash', 'dogecoin', 'litecoin']) {
        final account = fixture.service.accounts.singleWhere(
          (a) => a.chain == chain,
        );
        final formats = await fixture.client.accounts.addressFormats(
          account.accountId!,
          network: account.networkId!,
        );
        final expected = formats.formats.firstWhere((f) => f.isDefault).address;
        expect(account.address, expected);
        expect(await fixture.service.setCurrentAccount(account), isTrue);
        expect(fixture.service.currentAccount!.id, account.id);
        expect(fixture.service.currentAccount!.address, expected);
        expect(fixture.service.publicKey, expected);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('libw_address'), expected);
      }
      final selected = fixture.service.currentAccount!;
      fixture.close();
      fixture = await _Fixture.open(directory.path, library);
      await fixture.service.tryRestore();
      expect(fixture.service.currentAccount!.id, selected.id);
      expect(fixture.service.publicKey, selected.address);
      expect(fixture.backend.currentNetwork!.chainId, 'litecoin');
    },
  );

  test(
    'activation failure retries without reimporting or deleting accounts',
    () async {
      final group = await fixture.import();
      fixture.backend.failActivation = true;
      expect(await fixture.service.activateWalletGroup(group), isFalse);
      expect(fixture.backend.hasWallet, isFalse);
      fixture.backend.failActivation = false;
      expect(await fixture.service.activateWalletGroup(group), isTrue);
      await expectActivated(group);
      expect(await fixture.client.wallets.list(), hasLength(2));
      expect(await fixture.client.accounts.list(), hasLength(3));
    },
  );

  test('startup preserves an explicitly selected external account', () async {
    await fixture.import();
    final prefs = await SharedPreferences.getInstance();
    const external = '11111111111111111111111111111111';
    await prefs.setString('wallet_backend', 'mwa');
    await prefs.setString('wallet_public_key', external);
    await prefs.setString('current_account_id', 'mwa:$external');
    await fixture.service.tryRestore();
    expect(fixture.service.kind, WalletKind.mwa);
    expect(fixture.service.currentAccount!.isMwa, isTrue);
    expect(fixture.service.publicKey, external);
    expect(fixture.backend.hasWallet, isFalse);
  });

  test(
    'an empty store remains empty and does not manufacture a wallet',
    () async {
      await fixture.service.tryRestore();
      expect(fixture.service.currentAccount, isNull);
      expect(fixture.service.accounts, isEmpty);
      expect(fixture.backend.hasWallet, isFalse);
      expect(fixture.service.isConnected, isFalse);
      expect(fixture.service.dataReady, isTrue);
      expect(await fixture.client.wallets.list(), isEmpty);
    },
  );
}
