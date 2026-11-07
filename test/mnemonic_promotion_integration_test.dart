@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/mnemonic_migration.dart';

// Public BIP-39 test fixture, never a funded wallet.
const _mnemonic =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _password = 'fixture-import-password';

void main() {
  for (final (curve, type) in [
    ('ed25519', 'solana'),
    ('secp256k1', 'ethereum'),
  ]) {
    test(
      'native mnemonic migration capability for $type',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tibane-mnemonic-',
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
        final source = await client.wallets.importMnemonic(
          mnemonic: _mnemonic,
          curve: curve,
          name: 'Public fixture',
          keys: [KeyDescription.password(_password)],
        );
        final account = await client.accounts.create(
          wallet: source.id,
          type: type,
          index: 0,
          name: 'Original account',
          keys: [KeyDescription.password(_password).toJson()],
        );
        final migration = client.wallets.promoteMnemonic(
          source.id,
          oldKeys: [KeyDescription.password(_password)],
          chains: [
            ChainMigration(
              network: type,
              derivationPath: account.path,
              curve: curve,
              name: 'Migrated fixture',
            ),
          ],
          newKeys: [
            KeyDescription.password('fixture-first'),
            KeyDescription.password('fixture-second'),
            KeyDescription.password('fixture-third'),
          ],
          threshold: 1,
        );
        if (type == 'solana') {
          await expectLater(
            migration,
            throwsA(
              isA<LibwalletException>().having(
                (error) => error.message,
                'message',
                contains('curve ed25519 not yet supported'),
              ),
            ),
          );
          expect((await client.wallets.get(source.id)).id, source.id);
          expect(
            (await client.accounts.get(account.id)).address,
            account.address,
          );
          return;
        }
        final wallets = await migration;
        expect(wallets, hasLength(1));
        final target = wallets.single;
        expect(target.id, isNot(source.id));
        expect(target.curve, curve);
        expect(target.keys, hasLength(3));
        final migrated = await client.accounts.create(
          wallet: target.id,
          type: type,
          index: 0,
          name: 'Migrated account',
        );
        expect(migrated.wallet, target.id);
        expect(migrated.index, 0, reason: 'MPC default account index');
        expect(migrated.address.toLowerCase(), account.address.toLowerCase());
        expect(
          migrated.address.toLowerCase(),
          '0x9858effd232b4033e47d90003d41ec34ecaeda94',
        );
        expect(await client.wallets.get(source.id), isNotNull);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  for (final outcome in [
    'success',
    'custody-false',
    'custody-throws',
    'unsupported-solana',
  ]) {
    test(
      'app mnemonic migration $outcome keeps existing wallets intact',
      () async {
        final client = await _client();
        final existing = await client.wallets.importMnemonic(
          mnemonic: _mnemonic,
          passphrase: 'separate-existing-fixture',
          curve: 'secp256k1',
          name: 'Existing wallet',
          keys: [KeyDescription.password(_password)],
        );
        final existingAccount = await client.accounts.create(
          name: 'Existing account',
          wallet: existing.id,
          type: 'ethereum',
          keys: [KeyDescription.password(_password).toJson()],
        );
        final persisted = <String>[];
        final rolledBack = <String>[];
        final migration = importMnemonicAsMpc(
          client: client,
          mnemonic: _mnemonic,
          passphrase: '',
          curve: outcome == 'unsupported-solana' ? 'ed25519' : 'secp256k1',
          name: 'Imported fixture',
          password: _password,
          newKeys: [
            KeyDescription.password('fixture-first'),
            KeyDescription.password('fixture-second'),
            KeyDescription.password('fixture-third'),
          ],
          persistDeviceShare: (wallet) async {
            // The seed source must still exist until custody is confirmed.
            expect(await client.wallets.list(), hasLength(3));
            persisted.add(wallet.id);
            if (outcome == 'custody-throws') {
              throw StateError('Fixture storage error');
            }
            return outcome != 'custody-false';
          },
          rollbackDeviceShare: (wallet) async {
            rolledBack.add(wallet.id);
          },
        );
        if (outcome == 'success') {
          final result = await migration;
          expect(persisted, [result.id]);
          expect(rolledBack, isEmpty);
          expect(
            (await client.wallets.list()).map((wallet) => wallet.id).toSet(),
            {existing.id, result.id},
          );
          final account = (await client.accounts.list(
            wallet: result.id,
          )).singleWhere((account) => account.wallet == result.id);
          expect(
            account.address.toLowerCase(),
            '0x9858effd232b4033e47d90003d41ec34ecaeda94',
          );
          final signature = await client.accounts.signMessage(
            account.id,
            mode: 'evm',
            message: Uint8List.fromList('Offline migration fixture'.codeUnits),
            keys: [
              {
                'Id': result.keys[0].id,
                'Type': 'Password',
                'Key': 'fixture-first',
              },
              {
                'Id': result.keys[1].id,
                'Type': 'Password',
                'Key': 'fixture-second',
              },
              {
                'Id': result.keys[2].id,
                'Type': 'Password',
                'Key': 'fixture-third',
              },
            ],
          );
          expect(signature.signature, matches(RegExp(r'^0x[0-9a-fA-F]{130}$')));
        } else {
          await expectLater(
            migration,
            throwsA(
              outcome == 'unsupported-solana'
                  ? isA<LibwalletException>().having(
                      (e) => e.message,
                      'message',
                      contains('curve ed25519 not yet supported'),
                    )
                  : isA<StateError>(),
            ),
          );
          expect((await client.wallets.list()).map((wallet) => wallet.id), [
            existing.id,
          ]);
          if (outcome == 'unsupported-solana') {
            expect(persisted, isEmpty);
            expect(rolledBack, isEmpty);
          } else {
            expect(rolledBack, persisted);
          }
        }
        expect((await client.wallets.get(existing.id)).pubkey, existing.pubkey);
        expect(
          (await client.accounts.get(existingAccount.id)).address,
          existingAccount.address,
        );
        expect((await client.accounts.getCurrent()).id, existingAccount.id);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}

Future<LibwalletClient> _client() async {
  final directory = await Directory.systemTemp.createTemp(
    'tibane-mnemonic-app-',
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
  return client;
}
