@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/screens/wallet/widgets/account_switcher_view_model.dart';
import 'package:tibaneapp/services/wallet/solana_private_key.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';

DynamicLibrary _library() {
  final binary = Directory(
    '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
  ).listSync().whereType<File>().singleWhere((f) => f.path.endsWith('.dylib'));
  return DynamicLibrary.open(binary.path);
}

void main() {
  for (final chain in ['solana', 'ethereum']) {
    test(
      'raw SDK repeated $chain import permits duplicates without the app guard',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tibane-duplicate-key-$chain-',
        );
        final library = _library();
        var client = LibwalletClient.initialize(
          directory.path,
          library: library,
        );
        addTearDown(() async {
          client.dispose();
          await directory.delete(recursive: true);
        });
        await client.ready;
        expect(await client.info.version(), libwalletPackageVersion);
        final isSolana = chain == 'solana';
        // Public test vectors only: RFC8032 seed and secp256k1 scalar one.
        final key = isSolana
            ? (await normalizeSolanaPrivateKey(
                '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
              )).seedHex
            : normalizeEthereumPrivateKey(
                '0x0000000000000000000000000000000000000000000000000000000000000001',
              ).privateKeyHex;
        final imported = <Account>[];
        final walletIds = <String>[];
        for (final name in ['First import', 'Second import']) {
          final storeKey = await client.storeKeys.create();
          final wallet = await client.wallets.importPrivateKey(
            privateKey: key,
            curve: isSolana ? 'ed25519' : 'secp256k1',
            format: isSolana ? 'seed' : null,
            name: 'Selected wallet',
            keys: [KeyDescription.storeKey(storeKey.publicKey)],
          );
          walletIds.add(wallet.id);
          final account = await client.accounts.create(
            name: name,
            wallet: wallet.id,
            type: chain,
            index: 0,
          );
          await client.accounts.setCurrent(account.id);
          imported.add(account);
        }
        expect(walletIds.toSet(), hasLength(2));
        expect(imported.map((a) => a.id).toSet(), hasLength(2));
        expect(imported.map((a) => a.address).toSet(), hasLength(1));
        expect((await client.accounts.getCurrent()).id, imported.last.id);

        // This is persistent duplication, not a transient in-memory list.
        client.dispose();
        client = LibwalletClient.initialize(directory.path, library: library);
        await client.ready;
        final wallets = await client.wallets.list();
        final accounts = (await client.accounts.list())
            .where((a) => walletIds.contains(a.wallet))
            .toList();
        expect(wallets, hasLength(2));
        expect(accounts, hasLength(2));
        final unified = buildUnifiedAccounts(
          inappAccounts: accounts,
          walletsById: {for (final wallet in wallets) wallet.id: wallet},
        );
        expect(unified, hasLength(2));
        expect(unified.map((a) => a.address).toSet(), hasLength(1));
        final groups = buildAccountGroups(
          accounts: unified,
          wallets: wallets,
          unnamedLabel: 'Unnamed',
          attachedWalletParents: {walletIds.last: walletIds.first},
        );
        expect(groups, hasLength(1));
        expect(groups.single.additionalAccounts, hasLength(2));
        expect(
          groups.single.additionalAccounts.map((a) => a.accountName).toSet(),
          {'First import', 'Second import'},
        );
      },
    );
  }
}
