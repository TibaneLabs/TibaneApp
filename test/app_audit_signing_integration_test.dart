@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';

// All participants are local fixtures; no remote service or funds are used.
void main() {
  for (final (curve, chain) in [
    ('ed25519', 'solana'),
    ('secp256k1', 'ethereum'),
  ]) {
    test(
      'audit: fresh $chain MPC signing with two of three shares',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tibane-audit-',
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
        expect(await client.info.version(), libwalletPackageVersion);
        Wallet? created;
        final passwords = ['audit-first', 'audit-second', 'audit-third'];
        await for (final event in client.wallets.create(
          name: 'Offline audit fixture',
          curve: curve,
          keys: passwords.map(KeyDescription.password).toList(),
        )) {
          if (event is Complete<Wallet>) created = event.value;
        }
        final wallet = created!;
        expect(wallet.threshold, 1);
        final account = await client.accounts.create(
          wallet: wallet.id,
          name: 'Offline audit account',
          type: chain,
          index: 0,
        );
        final keys = [
          for (var i = 0; i < wallet.keys.length; i++)
            {'Id': wallet.keys[i].id, 'Type': 'Password', 'Key': passwords[i]},
        ];
        Future<SignedMessage> sign(List<int> participants) =>
            client.accounts.signMessage(
              account.id,
              mode: chain == 'ethereum' ? 'evm' : 'solana',
              message: Uint8List.fromList('Offline audit only'.codeUnits),
              keys: participants.map((index) => keys[index]).toList(),
            );
        for (final participants in [
          [0, 1],
          [1, 0],
          [0, 2],
          [2, 0],
          [1, 2],
          [2, 1],
          [0, 1, 2],
        ]) {
          expect((await sign(participants)).signature, isNotEmpty);
        }
        await expectLater(sign([0]), throwsA(isA<LibwalletException>()));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
