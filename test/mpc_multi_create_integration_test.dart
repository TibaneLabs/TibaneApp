@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';

void main() {
  test(
    'official multiCreate completes with the simulator committee shape offline',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tibane-multi-create-',
      );
      final binary =
          Directory(
            '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
          ).listSync().whereType<File>().singleWhere(
            (file) => file.path.endsWith('.dylib'),
          );
      final client = LibwalletClient.initialize(
        directory.path,
        library: DynamicLibrary.open(binary.path),
      );
      addTearDown(() async {
        client.dispose();
        await directory.delete(recursive: true);
      });
      await client.ready;
      for (final network in await client.networks.list()) {
        await client.networks.update(network.id, rpc: 'http://127.0.0.1:9');
      }
      // Two shares use the same password, as on a simulator without biometrics.
      // A third local password replaces RemoteKey ONLY in this offline control.
      Map<String, Wallet>? result;
      await for (final event in client.wallets.multiCreate(
        name: 'Offline fixture',
        keys: [
          KeyDescription.password('offline-fixture-password'),
          KeyDescription.password('offline-fixture-password'),
          KeyDescription.password('independent-third-fixture'),
        ],
      )) {
        if (event is Complete<Map<String, Wallet>>) result = event.value;
      }
      expect(result?.keys.toSet(), {'ed25519', 'secp256k1'});
      for (final entry in result!.entries) {
        expect(entry.value.threshold, 1);
        expect(entry.value.keys, hasLength(3));
        final account = await client.accounts.create(
          wallet: entry.value.id,
          name: 'Offline account',
          type: entry.key == 'ed25519' ? 'solana' : 'ethereum',
        );
        expect(account.address, isNotEmpty);
        expect(account.address, isNot('N/A'));
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
