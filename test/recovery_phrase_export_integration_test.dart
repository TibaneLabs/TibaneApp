@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/wallet_export_format.dart';

// Public BIP-39 vector; no user wallet or funded recovery phrase is used.
const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _password = 'offline-export-password';

class _Backend extends LibwalletBackend {
  _Backend(this.client, this.library);
  final LibwalletClient client;
  final DynamicLibrary library;
  @override
  Future<LibwalletClient> ensureClient() async => client;
  @override
  Future<LibwalletClient> createBackupValidationClient(String path) async =>
      LibwalletClient.initialize(path, library: library);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final curve in ['ed25519', 'secp256k1']) {
    test(
      '$curve seed exports words; importing its backup keeps JSON export',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tibane-export-format-',
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
        final sourceBackend = _Backend(source, library);
        final restoredBackend = _Backend(restored, library);
        addTearDown(() async {
          sourceBackend.dispose();
          restoredBackend.dispose();
          source.dispose();
          restored.dispose();
          await directory.delete(recursive: true);
        });
        await source.ready;
        await restored.ready;
        for (final client in [source, restored]) {
          for (final network in await client.networks.list()) {
            await client.networks.update(network.id, rpc: 'http://127.0.0.1:9');
          }
        }
        final wallet = await sourceBackend.importMnemonicWallet(
          mnemonic: _phrase,
          passphrase: 'public BIP39 extra password',
          curve: curve,
          name: 'Offline export fixture',
          password: _password,
        );
        final before = (await source.accounts.list(
          wallet: wallet.id,
        )).where((account) => account.wallet == wallet.id).toList();
        final secret = await sourceBackend.exportRecoveryPhrase(
          walletId: wallet.id,
          password: _password,
        );
        expect(secret.mnemonic, _phrase);
        expect(secret.passphrase, 'public BIP39 extra password');
        expect(secret.privateKey, isNull);
        await expectLater(
          sourceBackend.exportRecoveryPhrase(
            walletId: wallet.id,
            password: 'wrong',
          ),
          throwsStateError,
        );
        final after = (await source.accounts.list(
          wallet: wallet.id,
        )).where((account) => account.wallet == wallet.id).toList();
        expect(
          after.map((account) => account.address),
          before.map((account) => account.address),
        );

        final backup = await sourceBackend.exportBackupJson(
          _password,
          walletIds: {wallet.id},
        );
        expect(backup, isNot(contains(_phrase)));
        expect(backup, isNot(contains('public BIP39 extra password')));
        expect(
          await restoredBackend.importFromBackup(
            backupJson: backup,
            password: 'wrong',
          ),
          isFalse,
        );
        expect(await WalletExportPolicy.backupImports(), isEmpty);
        expect(
          await restoredBackend.importFromBackup(
            backupJson: backup,
            password: _password,
          ),
          isTrue,
        );
        final restoredWallet = await restored.wallets.get(wallet.id);
        expect(restoredWallet.protocol, 'mnemonic');
        expect(
          WalletExportPolicy.formatFor(
            restoredWallet,
            backupImports: await WalletExportPolicy.backupImports(),
          ),
          WalletExportFormat.backup,
        );
        await expectLater(
          restoredBackend.exportRecoveryPhrase(
            walletId: wallet.id,
            password: _password,
          ),
          throwsStateError,
        );
        final reexported = await restoredBackend.exportBackupJson(
          _password,
          walletIds: {wallet.id},
        );
        expect(jsonDecode(reexported), isNotEmpty);
        expect(reexported, isNot(contains(_phrase)));
        expect(
          (await restored.accounts.get(before.first.id)).address,
          before.first.address,
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
