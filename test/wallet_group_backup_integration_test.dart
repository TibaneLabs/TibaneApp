@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/utils/wallet_error.dart';

class _Backend extends LibwalletBackend {
  _Backend(this.client);
  final LibwalletClient client;
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'group backup exports only selected wallets and restores all their accounts',
    () async {
      final dir = await Directory.systemTemp.createTemp('tibane-group-backup-');
      final restoreDir = await Directory.systemTemp.createTemp(
        'tibane-group-restore-',
      );
      final binary =
          Directory(
            '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
          ).listSync().whereType<File>().singleWhere(
            (file) => file.path.endsWith('.dylib'),
          );
      final library = DynamicLibrary.open(binary.path);
      final source = LibwalletClient.initialize(dir.path, library: library);
      var sourceClosed = false;
      final backend = _Backend(source);
      LibwalletClient? restored;
      addTearDown(() async {
        if (!sourceClosed) source.dispose();
        restored?.dispose();
        backend.dispose();
        await dir.delete(recursive: true);
        await restoreDir.delete(recursive: true);
      });
      await source.ready;
      final wallets = <Wallet>[];
      final accounts = <Account>[];
      for (var i = 0; i < 3; i++) {
        Wallet? wallet;
        await for (final event in source.wallets.create(
          name: 'Public group fixture $i',
          curve: 'ed25519',
          keys: [
            KeyDescription.password('fixture-password'),
            KeyDescription.password('second-fixture-password'),
            KeyDescription.password('third-fixture-password'),
          ],
        )) {
          if (event is Complete<Wallet>) wallet = event.value;
        }
        wallets.add(wallet!);
        accounts.add(
          await source.accounts.create(
            name: 'Fixture $i',
            wallet: wallet.id,
            type: 'solana',
            index: 0,
          ),
        );
        accounts.add(
          await source.accounts.create(
            name: 'Derived fixture $i',
            wallet: wallet.id,
            type: 'solana',
            index: 1,
          ),
        );
      }
      final selected = wallets.take(2).map((wallet) => wallet.id).toSet();
      final store = await source.storeKeys.create();
      final imported = await source.wallets.importPrivateKey(
        privateKey:
            '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
        curve: 'ed25519',
        format: 'seed',
        name: 'Public RFC8032 fixture',
        keys: [KeyDescription.storeKey(store.publicKey)],
      );
      await expectLater(
        backend.exportBackupJson('fixture-password', walletIds: {imported.id}),
        throwsA(
          predicate<Object>(
            (error) =>
                WalletError.from(error).key ==
                WalletErrorKey.privateKeyWalletBackup,
          ),
        ),
      );
      await expectLater(
        backend.exportBackupJson('wrong-password', walletIds: selected),
        throwsStateError,
      );
      final json = await backend.exportBackupJson(
        'fixture-password',
        walletIds: selected,
      );
      final files = (jsonDecode(json) as List)
          .map((entry) => Map<String, String>.from(entry as Map))
          .toList();
      expect(files, isNotEmpty);
      source.dispose();
      sourceClosed = true;
      restored = LibwalletClient.initialize(restoreDir.path, library: library);
      await restored.ready;
      await restored.wallets.restore(files);
      expect(
        (await restored.wallets.list()).map((wallet) => wallet.id).toSet(),
        selected,
      );
      expect(
        (await restored.accounts.list())
            .map((account) => account.address)
            .toSet(),
        accounts
            .where((account) => selected.contains(account.wallet))
            .map((account) => account.address)
            .toSet(),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
