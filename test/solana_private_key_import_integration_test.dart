@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/solana_common.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/solana_private_key.dart';

class _Backend extends LibwalletBackend {
  _Backend(this.client);

  final LibwalletClient client;

  @override
  Future<LibwalletClient> ensureClient() async => client;
}

void main() {
  test('Solana seed import preserves its RFC 8032 address', () async {
    const seedHex =
        '9d61b19deffd5a60ba844af492ec2cc4'
        '4449c5697b326919703bac031cae7f60';
    final normalized = await normalizeSolanaPrivateKey(seedHex);
    final dataDir = await Directory.systemTemp.createTemp(
      'tibane-solana-import-',
    );
    addTearDown(() => dataDir.delete(recursive: true));

    final client = LibwalletClient.initialize(
      dataDir.path,
      library: _openNativeLibrary(),
    );
    addTearDown(client.dispose);
    await client.ready;
    final backend = _Backend(client);
    addTearDown(backend.dispose);

    Future<String> importAddress(
      String name,
      String key, {
      String? format,
    }) async {
      final storeKey = await client.storeKeys.create();
      final wallet = await client.wallets.importPrivateKey(
        privateKey: key,
        format: format,
        curve: 'ed25519',
        name: name,
        keys: [KeyDescription.storeKey(storeKey.publicKey)],
      );
      final account = await client.accounts.create(
        name: name,
        wallet: wallet.id,
        type: 'solana',
        index: 0,
      );
      expect(
        await backend.createAccount(
          walletId: wallet.id,
          name: 'Do not derive',
          type: 'solana',
        ),
        isNull,
      );
      expect(
        (await client.accounts.list())
            .where((candidate) => candidate.wallet == wallet.id)
            .map((candidate) => candidate.id),
        [account.id],
      );
      return account.address;
    }

    final seed = Uint8List.fromList([
      for (var i = 0; i < seedHex.length; i += 2)
        int.parse(seedHex.substring(i, i + 2), radix: 16),
    ]);
    final secret = Uint8List.fromList([
      ...seed,
      ...base58Decode(normalized.address),
    ]);
    final addresses = [
      await importAddress('Hex seed', normalized.seedHex, format: 'seed'),
      await importAddress('Phantom export', base58Encode(secret)),
      await importAddress('JSON export', jsonEncode(secret)),
      await importAddress('Base58 seed', base58Encode(seed)),
    ];
    expect(addresses, everyElement(normalized.address));
  });
}

DynamicLibrary _openNativeLibrary() {
  final nativeBuildDir = Directory(
    '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
  );
  final nativeBinary = nativeBuildDir.listSync().whereType<File>().singleWhere(
    (file) => file.path.endsWith('.dylib'),
  );
  return DynamicLibrary.open(nativeBinary.path);
}
