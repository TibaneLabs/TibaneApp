@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/solana_common.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/signing.dart';

// Public BIP-39 vector, never funded or taken from a user's wallet.
const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _password = 'offline-import-password';

class _Backend extends LibwalletBackend {
  _Backend(this.client);
  final LibwalletClient client;
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final (curve, type) in [
    ('ed25519', 'solana'),
    ('secp256k1', 'ethereum'),
  ]) {
    test(
      'normal $type phrase import stays single-key, signs, derives and backs up without MPC',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tibane-normal-phrase-test-',
        );
        final binary =
            Directory(
              '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
            ).listSync().whereType<File>().singleWhere(
              (f) => f.path.endsWith('.dylib'),
            );
        final library = DynamicLibrary.open(binary.path);
        final client = LibwalletClient.initialize(
          '${directory.path}/live',
          library: library,
        );
        final restored = LibwalletClient.initialize(
          '${directory.path}/restored',
          library: library,
        );
        final backend = _Backend(client);
        addTearDown(() async {
          backend.dispose();
          client.dispose();
          restored.dispose();
          await directory.delete(recursive: true);
        });
        await client.ready;
        await restored.ready;
        expect(await client.info.version(), libwalletPackageVersion);
        for (final network in await client.networks.list()) {
          await client.networks.update(network.id, rpc: 'http://127.0.0.1:9');
        }
        final existing = await client.wallets.importMnemonic(
          mnemonic: _phrase,
          passphrase: 'different-public-fixture',
          curve: curve,
          name: 'Existing',
          keys: [KeyDescription.password(_password)],
        );
        final existingAccount = await client.accounts.create(
          wallet: existing.id,
          name: 'Existing account',
          type: type,
          keys: [KeyDescription.password(_password).toJson()],
        );

        final wallet = await backend.importMnemonicWallet(
          mnemonic: _phrase,
          passphrase: '',
          curve: curve,
          name: 'Normal import',
          password: _password,
        );
        expect(wallet.protocol, 'mnemonic');
        expect(wallet.threshold, 0);
        expect(wallet.keys, hasLength(1));
        expect(wallet.keys.single.type, 'Password');
        expect(canAssembleThreshold(wallet), true);
        expect(requiredSigningShares(wallet.threshold), 1);
        expect((await client.accounts.getCurrent()).id, existingAccount.id);
        final accounts = (await client.accounts.list())
            .where((a) => a.wallet == wallet.id)
            .toList();
        expect(
          accounts.map((a) => a.type).toSet(),
          type == 'solana' ? {'solana'} : {'ethereum', 'bitcoin'},
        );
        final first = accounts.singleWhere((a) => a.type == type);
        if (type == 'ethereum') {
          expect(
            first.address.toLowerCase(),
            '0x9858effd232b4033e47d90003d41ec34ecaeda94',
          );
        }
        final keys = [
          SigningKey(
            id: wallet.keys.single.id,
            type: 'Password',
            key: _password,
          ),
        ];
        final keyMaps = keys.map((k) => k.toJson()).toList();
        final message = Uint8List.fromList(
          'Offline normal import check'.codeUnits,
        );
        final signature = await client.accounts.signMessage(
          first.id,
          mode: type == 'solana' ? 'solana' : 'evm',
          message: message,
          keys: keyMaps,
        );
        if (type == 'solana') {
          expect(
            await Ed25519().verify(
              message,
              signature: Signature(
                base58Decode(signature.signature),
                publicKey: SimplePublicKey(
                  base58Decode(first.address),
                  type: KeyPairType.ed25519,
                ),
              ),
            ),
            true,
          );
        } else {
          expect(signature.signature, matches(RegExp(r'^0x[0-9a-fA-F]{130}$')));
        }
        await expectLater(
          client.accounts.signMessage(
            first.id,
            mode: type == 'solana' ? 'solana' : 'evm',
            message: message,
            keys: [
              SigningKey(
                id: wallet.keys.single.id,
                type: 'Password',
                key: 'wrong-password',
              ).toJson(),
            ],
          ),
          throwsA(isA<LibwalletException>()),
        );
        final next = await backend.createAccount(
          walletId: wallet.id,
          name: 'Account 2',
          type: type,
          keys: keys,
        );
        expect(next, isNotNull);
        expect(next!.index, 1);
        expect(next.address, isNot(first.address));
        final derivedSignature = await client.accounts.signMessage(
          next.id,
          mode: type == 'solana' ? 'solana' : 'evm',
          message: message,
          keys: keyMaps,
        );
        expect(derivedSignature.signature, isNotEmpty);
        final backup = await backend.exportBackupJson(
          _password,
          walletIds: {wallet.id},
        );
        await expectLater(
          backend.exportBackupJson('wrong-password', walletIds: {wallet.id}),
          throwsStateError,
        );
        await restored.wallets.restore(
          (jsonDecode(backup) as List)
              .map((f) => Map<String, String>.from(f as Map))
              .toList(),
        );
        final restoredWallet = await restored.wallets.get(wallet.id);
        expect(restoredWallet.protocol, 'mnemonic');
        expect(restoredWallet.threshold, 0);
        expect((await restored.accounts.get(first.id)).address, first.address);
        expect((await restored.accounts.get(next.id)).address, next.address);
        final count = (await client.accounts.list()).length;
        await expectLater(
          backend.importMnemonicWallet(
            mnemonic: _phrase,
            passphrase: '',
            curve: curve,
            name: 'Duplicate',
            password: 'another-password',
          ),
          throwsA(isA<PrivateKeyAccountExistsException>()),
        );
        expect((await client.wallets.list()).map((w) => w.id).toSet(), {
          existing.id,
          wallet.id,
        });
        expect(await client.accounts.list(), hasLength(count));
        expect((await client.accounts.getCurrent()).id, next.id);
        await expectLater(
          backend.importMnemonicWallet(
            mnemonic: 'invalid recovery phrase',
            passphrase: '',
            curve: curve,
            name: 'Invalid',
            password: _password,
          ),
          throwsA(isA<LibwalletException>()),
        );
        expect((await client.wallets.list()).map((w) => w.id).toSet(), {
          existing.id,
          wallet.id,
        });
        // An independent BIP-39 passphrase selects another ordinary wallet.
        final independent = await backend.importMnemonicWallet(
          mnemonic: _phrase,
          passphrase: 'another-public-fixture',
          curve: curve,
          name: 'Independent',
          password: _password,
        );
        expect(independent.id, isNot(wallet.id));
        expect(independent.protocol, 'mnemonic');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
