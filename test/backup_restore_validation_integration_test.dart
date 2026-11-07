@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/wallet_group_store.dart';

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

Future<Wallet> _create(LibwalletClient client, String curve) async {
  Wallet? result;
  await for (final event in client.wallets.create(
    name: 'Offline fixture',
    curve: curve,
    keys: [
      KeyDescription.password('fixture-password'),
      KeyDescription.password('fixture-password'),
      KeyDescription.password('third-fixture-password'),
    ],
  )) {
    if (event is Complete<Wallet>) result = event.value;
  }
  return result!;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'backup validation protects existing wallets and supports EVM-only and duplicate imports',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tibane-restore-validation-test-',
      );
      final binary = Directory(
        '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
      ).listSync().whereType<File>().singleWhere((f) => f.path.endsWith('.dylib'));
      final library = DynamicLibrary.open(binary.path);
      final source = LibwalletClient.initialize(
        '${directory.path}/source',
        library: library,
      );
      await source.ready;
      final solana = await _create(source, 'ed25519');
      final ethereum = await _create(source, 'secp256k1');
      final ethAccount = await source.accounts.create(
        name: 'Ethereum',
        wallet: ethereum.id,
        type: 'ethereum',
        index: 0,
      );
      await source.accounts.create(
        name: 'Solana',
        wallet: solana.id,
        type: 'solana',
        index: 0,
      );
      await WalletGroupStore.associate([solana.id, ethereum.id]);
      final exporter = _Backend(source, library);
      final groupBackup = await exporter.exportBackupJson(
        'fixture-password',
        walletIds: {solana.id, ethereum.id},
      );
      final evmBackup = jsonEncode(
        (await source.wallets.backup(
          ethereum.id,
        )).map((f) => f.toJson()).toList(),
      );
      exporter.dispose();
      source.dispose();
      SharedPreferences.setMockInitialValues({});
      final live = LibwalletClient.initialize(
        '${directory.path}/live',
        library: library,
      );
      await live.ready;
      final backend = _Backend(live, library);
      addTearDown(() async {
        backend.dispose();
        live.dispose();
        await directory.delete(recursive: true);
      });
      final existing = await _create(live, 'ed25519');
      final existingAccount = await live.accounts.create(
        name: 'Existing',
        wallet: existing.id,
        type: 'solana',
      );
      expect(
        await backend.importFromBackup(
          backupJson: groupBackup,
          password: 'wrong-password',
        ),
        false,
      );
      expect((await live.wallets.list()).map((w) => w.id), [existing.id]);
      expect((await live.accounts.getCurrent()).id, existingAccount.id);
      expect(
        await backend.importFromBackup(
          backupJson: evmBackup,
          password: 'fixture-password',
        ),
        true,
      );
      expect(backend.walletId, ethereum.id);
      expect(backend.publicKey, ethAccount.address);
      expect(backend.currentNetwork?.type, NetworkType.evm);
      expect(
        await backend.importFromBackup(
          backupJson: evmBackup,
          password: 'fixture-password',
        ),
        true,
      );
      expect((await live.wallets.list()).map((w) => w.id).toSet(), {
        existing.id,
        ethereum.id,
      });
      expect(
        await backend.importFromBackup(
          backupJson: groupBackup,
          password: 'fixture-password',
        ),
        true,
      );
      expect((await live.wallets.list()).map((w) => w.id).toSet(), {
        existing.id,
        ethereum.id,
        solana.id,
      });
      final groups = await WalletGroupStore.read();
      expect(groups[solana.id], groups[ethereum.id]);
      expect((await live.wallets.get(existing.id)).pubkey, existing.pubkey);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
