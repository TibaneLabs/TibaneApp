@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

class _Backend extends LibwalletBackend {
  _Backend(this.client);
  final LibwalletClient client;
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

void main() {
  test('deleting an imported wallet preserves unrelated accounts', () async {
    final dir = await Directory.systemTemp.createTemp('tibane-delete-fixture-');
    final binary = Directory(
      '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
    ).listSync().whereType<File>().singleWhere((f) => f.path.endsWith('.dylib'));
    final client = LibwalletClient.initialize(
      dir.path,
      library: DynamicLibrary.open(binary.path),
    );
    addTearDown(() async {
      client.dispose();
      await dir.delete(recursive: true);
    });
    await client.ready;
    final wallets = <Wallet>[];
    final accounts = <Account>[];
    for (final seed in [
      '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
      '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
    ]) {
      final store = await client.storeKeys.create();
      final wallet = await client.wallets.importPrivateKey(
        name: 'Public deletion fixture',
        privateKey: seed,
        curve: 'ed25519',
        format: 'seed',
        keys: [KeyDescription.storeKey(store.publicKey)],
      );
      wallets.add(wallet);
      accounts.add(
        await client.accounts.create(
          name: 'Fixture',
          wallet: wallet.id,
          type: 'solana',
          index: 0,
        ),
      );
    }
    expect(
      (await client.accounts.list()).map((a) => a.id),
      containsAll(accounts.map((a) => a.id)),
    );
    await LibwalletBackend.deleteAccountsForRemovedWallet(
      client,
      wallets.first.id,
    );
    expect(
      (await client.accounts.list()).map((a) => a.id),
      contains(accounts.last.id),
    );
    final backend = _Backend(client);
    addTearDown(backend.dispose);
    final partialRecovery = await backend.ensureDefaultAccountsForWallets(
      accounts: await client.accounts.list(),
      walletsById: {for (final wallet in wallets) wallet.id: wallet},
      alreadyEnsured: wallets.map((wallet) => wallet.id).toSet(),
    );
    expect(partialRecovery.accounts, hasLength(2));
    expect(
      partialRecovery.accounts
          .singleWhere((a) => a.wallet == wallets.first.id)
          .address,
      accounts.first.address,
    );
    expect(
      partialRecovery.accounts
          .singleWhere((a) => a.wallet == wallets.last.id)
          .id,
      accounts.last.id,
    );
    await LibwalletBackend.deleteAccountsForRemovedWallet(
      client,
      wallets.first.id,
    );
    await client.wallets.delete(wallets.first.id);
    expect(
      (await client.wallets.list()).map((w) => w.id),
      contains(wallets.last.id),
    );
    expect(
      (await client.accounts.list()).map((a) => a.id),
      contains(accounts.last.id),
    );
    await client.accounts.delete(accounts.last.id);
    final recovered = await backend.ensureDefaultAccountsForWallets(
      accounts: [],
      walletsById: {wallets.last.id: wallets.last},
      alreadyEnsured: {wallets.last.id},
    );
    expect(recovered.accounts.single.wallet, wallets.last.id);
    expect(recovered.accounts.single.index, 0);
    expect(recovered.accounts.single.address, accounts.last.address);
  });
}
