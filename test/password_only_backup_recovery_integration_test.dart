@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/solana_common.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

class _Backend extends LibwalletBackend {
  _Backend(this.client, this.target);
  final LibwalletClient client;
  final String target;
  @override
  String get walletId => target;
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

void main() {
  test(
    'password-only backup restores and signs without StoreKey or remote calls',
    () async {
      final sourceDir = await Directory.systemTemp.createTemp(
        'tibane-password-source-',
      );
      final restoreDir = await Directory.systemTemp.createTemp(
        'tibane-password-restore-',
      );
      final binary =
          Directory(
            '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
          ).listSync().whereType<File>().singleWhere(
            (file) => file.path.endsWith('.dylib'),
          );
      final library = DynamicLibrary.open(binary.path);
      var client = LibwalletClient.initialize(sourceDir.path, library: library);
      addTearDown(() async {
        client.dispose();
        await sourceDir.delete(recursive: true);
        await restoreDir.delete(recursive: true);
      });
      await client.ready;
      // Local password participants exercise the same offline T+1 path as the
      // two Password shares in the app's D5 committee; no WalletSign account.
      Wallet? wallet;
      await for (final event in client.wallets.create(
        name: 'Temporary password-only fixture',
        curve: 'ed25519',
        keys: [
          KeyDescription.password('fixture-password'),
          KeyDescription.password('fixture-password'),
          KeyDescription.password('third-fixture-password'),
        ],
      )) {
        if (event is Complete<Wallet>) wallet = event.value;
      }
      final original = wallet!;
      final account = await client.accounts.create(
        wallet: original.id,
        type: 'solana',
        index: 0,
        name: 'Public account fixture',
      );
      final files = await client.wallets.backup(original.id);
      client.dispose();
      client = LibwalletClient.initialize(restoreDir.path, library: library);
      await client.ready;
      await client.wallets.restore(files.map((file) => file.toJson()).toList());
      final restored = await client.wallets.get(original.id);
      expect(restored.pubkey, original.pubkey);
      expect(restored.keys.any((key) => key.isStoreKey), isFalse);
      final backend = _Backend(client, restored.id);
      addTearDown(backend.dispose);
      expect(
        await backend.walletCanSignWithoutDeviceShare(restored.id),
        isTrue,
      );
      expect(
        await backend.recoverDeviceShareVia2fa(
          sessionToken: 'offline-no-session',
          code: 'unused',
          password: 'wrong-password',
        ),
        isFalse,
      );
      expect(backend.error, contains('Wrong password'));
      expect(
        await backend.recoverDeviceShareVia2fa(
          sessionToken: 'offline-no-session',
          code: 'unused',
          password: 'fixture-password',
        ),
        isTrue,
      );
      expect(backend.error, isNull);
      final after = await client.wallets.get(restored.id);
      expect(after.pubkey, original.pubkey);
      expect(after.gen, original.gen);
      expect(
        after.keys.map((key) => key.id),
        original.keys.map((key) => key.id),
      );
      final restoredAccount = await client.accounts.get(account.id);
      expect(restoredAccount.address, account.address);
      final message = Uint8List.fromList(
        'Offline backup recovery fixture'.codeUnits,
      );
      final result = await client.accounts.signMessage(
        account.id,
        mode: 'solana',
        message: message,
        keys: after.keys
            .take(2)
            .map(
              (key) => {
                'Id': key.id,
                'Type': 'Password',
                'Key': 'fixture-password',
              },
            )
            .toList(),
      );
      expect(
        await Ed25519().verify(
          message,
          signature: Signature(
            base58Decode(result.signature),
            publicKey: SimplePublicKey(
              base58Decode(account.address),
              type: KeyPairType.ed25519,
            ),
          ),
        ),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
