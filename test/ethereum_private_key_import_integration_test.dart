@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';

void main() {
  test(
    'Ethereum private-key import preserves its address deterministically',
    () async {
      final dataDir = await Directory.systemTemp.createTemp(
        'tibane-ethereum-import-',
      );
      final nativeLibrary = _openNativeLibrary();
      final client = LibwalletClient.initialize(
        dataDir.path,
        library: nativeLibrary,
      );
      await client.ready;

      Future<String> importAddress(String name) async {
        final storeKey = await client.storeKeys.create();
        final wallet = await client.wallets.importPrivateKey(
          // secp256k1 scalar 1 has a stable, well-known Ethereum address.
          privateKey:
              '0000000000000000000000000000000000000000000000000000000000000001',
          curve: 'secp256k1',
          name: name,
          keys: [KeyDescription.storeKey(storeKey.publicKey)],
        );
        final account = await client.accounts.create(
          name: name,
          wallet: wallet.id,
          type: 'ethereum',
          index: 0,
        );
        return account.address.toLowerCase();
      }

      final first = await importAddress('First import');
      final second = await importAddress('Second import');

      expect(first, '0x7e5f4552091a69125d5dfcb7b8c2659029395bdf');
      expect(second, first);

    },
  );
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
