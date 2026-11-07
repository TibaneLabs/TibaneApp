@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/solana_private_key.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

class _Backend extends LibwalletBackend {
  _Backend(this.client);
  final LibwalletClient client;
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

const _seed =
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';

void main() {
  test(
    'official export and mixed-key promotion preserve imported Solana identity',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tibane-public-export-',
      );
      final build = Directory(
        '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
      );
      final native = build.listSync().whereType<File>().singleWhere(
        (f) => f.path.endsWith('.dylib'),
      );
      final client = LibwalletClient.initialize(
        directory.path,
        library: DynamicLibrary.open(native.path),
      );
      addTearDown(() async {
        client.dispose();
        await directory.delete(recursive: true);
      });
      await client.ready;
      final store = await client.storeKeys.create();
      final wallet = await client.wallets.importPrivateKey(
        privateKey: _seed,
        curve: 'ed25519',
        format: 'seed',
        name: 'Public RFC8032 fixture',
        keys: [KeyDescription.storeKey(store.publicKey)],
      );
      final account = await client.accounts.create(
        wallet: wallet.id,
        type: 'solana',
        index: 0,
        name: 'Public fixture',
      );
      final old = KeyDescription(
        type: 'StoreKey',
        key: store.privateKey,
        id: wallet.keys.single.id,
      );
      final other = await client.accounts.createView(
        type: 'solana',
        name: 'Other public address',
        address: 'HSYatVptUXtn4f5JeDBzRhceG5LoMnsL4CizfFjxS83y',
      );
      await client.accounts.setCurrent(other.id);
      final backend = _Backend(client);
      addTearDown(backend.dispose);
      final exported = await backend.exportImportedPrivateKey(
        accountId: account.id,
        keys: [old],
      );
      expect((await client.accounts.getCurrent()).id, other.id);
      expect(exported.format, 'keypair');
      expect(
        (await normalizeSolanaPrivateKey(exported.privateKey!)).address,
        account.address,
      );
      final stores = [
        await client.storeKeys.create(),
        await client.storeKeys.create(),
      ];
      await client.wallets.promote(
        wallet.id,
        oldKeys: [old],
        newKeys: [
          for (final s in stores) KeyDescription.storeKey(s.publicKey),
          KeyDescription.password('public-fixture-password'),
        ],
        threshold: 1,
      );
      final promoted = await client.wallets.get(wallet.id);
      expect(promoted.pubkey, wallet.pubkey);
      expect((await client.accounts.get(account.id)).address, account.address);
      await expectLater(
        client.wallets.exportSecret(wallet.id, keys: [old]),
        throwsA(isA<LibwalletException>()),
      );
      await expectLater(
        backend.exportImportedPrivateKey(accountId: account.id, keys: [old]),
        throwsStateError,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
