@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/wallet_export_format.dart';

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
    for (final words in [12, 24]) {
      test(
        'native $words-word $type creation exports the same seed and recreates derived accounts',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'tibane-seed-create-',
          );
          final binary =
              Directory(
                '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
              ).listSync().whereType<File>().singleWhere(
                (file) => file.path.endsWith('.dylib'),
              );
          final library = DynamicLibrary.open(binary.path);
          final source = LibwalletClient.initialize(
            '${directory.path}/source',
            library: library,
          );
          final restored = LibwalletClient.initialize(
            '${directory.path}/restored',
            library: library,
          );
          final backend = _Backend(source);
          final restoredBackend = _Backend(restored);
          addTearDown(() async {
            backend.dispose();
            restoredBackend.dispose();
            source.dispose();
            restored.dispose();
            await directory.delete(recursive: true);
          });
          await source.ready;
          await restored.ready;
          for (final client in [source, restored]) {
            for (final network in await client.networks.list()) {
              await client.networks.update(
                network.id,
                rpc: 'http://127.0.0.1:9',
              );
            }
          }
          // Fresh, unfunded test-only entropy. No words are logged or committed.
          final phrase = await backend.generateRecoveryPhrase(words: words);
          expect(phrase.split(' '), hasLength(words));
          expect(await source.wallets.list(), isEmpty);
          final wallet = await backend.importMnemonicWallet(
            mnemonic: phrase,
            passphrase: '',
            curve: curve,
            name: 'Generated seed fixture',
            password: 'first-fixture-password',
          );
          expect(wallet.protocol, 'mnemonic');
          expect(wallet.threshold, 0);
          expect(wallet.keys, hasLength(1));
          expect(wallet.keys.single.type, 'Password');
          expect(
            WalletExportPolicy.formatFor(wallet),
            WalletExportFormat.recoveryPhrase,
          );
          final secret = await backend.exportRecoveryPhrase(
            walletId: wallet.id,
            password: 'first-fixture-password',
          );
          expect(secret.mnemonic, phrase);
          final keys = [
            SigningKey(
              id: wallet.keys.single.id,
              type: 'Password',
              key: 'first-fixture-password',
            ),
          ];
          final derived = await backend.createAccount(
            walletId: wallet.id,
            name: 'Account 2',
            type: type,
            keys: keys,
          );
          expect(derived, isNotNull);
          expect(derived!.index, 1);
          final signed = await source.accounts.signMessage(
            derived.id,
            mode: type == 'solana' ? 'solana' : 'evm',
            message: Uint8List.fromList(
              'Offline seed creation fixture'.codeUnits,
            ),
            keys: keys.map((key) => key.toJson()).toList(),
          );
          expect(signed.signature, isNotEmpty);
          final reopened = await restoredBackend.importMnemonicWallet(
            mnemonic: phrase,
            passphrase: '',
            curve: curve,
            name: 'Restored seed fixture',
            password: 'different-local-password',
          );
          final recreated = await restoredBackend.createAccount(
            walletId: reopened.id,
            name: 'Account 2',
            type: type,
            keys: [
              SigningKey(
                id: reopened.keys.single.id,
                type: 'Password',
                key: 'different-local-password',
              ),
            ],
          );
          expect(recreated!.address, derived.address);
          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.getKeys().map((key) => prefs.get(key)).join(),
            isNot(contains(phrase)),
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
}
