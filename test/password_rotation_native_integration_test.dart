@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/solana_common.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/password_rotation.dart';

class _Backend extends LibwalletBackend {
  _Backend(this.client);
  final LibwalletClient client;
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final (curve, chain) in [
    ('ed25519', 'solana'),
    ('secp256k1', 'ethereum'),
  ]) {
    test(
      'offline $chain password rotation preserves the address, signing and backup',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'tibane-password-rotation-',
        );
        final binary =
            Directory(
              '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
            ).listSync().whereType<File>().singleWhere(
              (f) => f.path.endsWith('.dylib'),
            );
        final client = LibwalletClient.initialize(
          dir.path,
          library: DynamicLibrary.open(binary.path),
        );
        final backend = _Backend(client);
        addTearDown(() async {
          backend.dispose();
          client.dispose();
          await dir.delete(recursive: true);
        });
        await client.ready;
        Wallet? wallet;
        // Two local Password authorizers; the third is an offline stand-in for
        // the dormant participant, never a live RemoteKey/email ceremony.
        await for (final event in client.wallets.create(
          name: 'Offline fixture',
          curve: curve,
          keys: [
            KeyDescription.password('old-password'),
            KeyDescription.password('old-password'),
            KeyDescription.password('dormant-fixture'),
          ],
        )) {
          if (event is Complete<Wallet>) wallet = event.value;
        }
        final account = await client.accounts.create(
          name: 'Fixture',
          wallet: wallet!.id,
          type: chain,
        );
        final plans = await preparePasswordRotation(
          wallets: [wallet],
          oldPassword: 'old-password',
          newPassword: 'new-password',
          passwordMatches: (_, password) async => password == 'old-password',
          readStoreSecret: (_, _, _) async => null,
        );
        Wallet? rotated;
        await executePasswordRotation(
          plans: plans,
          newPassword: 'new-password',
          remoteKey: 'unused',
          reshare: (plan, keys) async {
            await for (final event in client.wallets.reshare(
              plan.wallet.id,
              oldKeys: plan.oldKeys,
              newKeys: keys,
            )) {
              if (event is Complete<Wallet>) rotated = event.value;
            }
            return rotated!;
          },
          persist: (_, _) async {},
          journal: (_) async {},
        );
        expect(rotated!.pubkey, wallet.pubkey);
        expect(
          (await client.accounts.get(account.id)).address,
          account.address,
        );
        final message = Uint8List.fromList(
          'Offline password rotation fixture'.codeUnits,
        );
        final signed = await client.accounts.signMessage(
          account.id,
          mode: chain == 'solana' ? 'solana' : 'evm',
          message: message,
          keys: rotated!.keys
              .take(chain == 'solana' ? 2 : 3)
              .map(
                (key) => {
                  'Id': key.id,
                  'Type': 'Password',
                  'Key': 'new-password',
                },
              )
              .toList(),
        );
        if (chain == 'solana') {
          expect(
            await Ed25519().verify(
              message,
              signature: Signature(
                base58Decode(signed.signature),
                publicKey: SimplePublicKey(
                  base58Decode(account.address),
                  type: KeyPairType.ed25519,
                ),
              ),
            ),
            true,
          );
        } else {
          expect(signed.signature, matches(RegExp(r'^0x[0-9a-fA-F]{130}$')));
        }
        expect(
          await backend.exportBackupJson(
            'new-password',
            walletIds: {wallet.id},
          ),
          isNotEmpty,
        );
        await expectLater(
          backend.exportBackupJson('old-password', walletIds: {wallet.id}),
          throwsStateError,
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
