@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/accounts_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/mwa_wallet_backend.dart';

class _Backend extends LibwalletBackend {
  _Backend(this.client);
  final LibwalletClient client;
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('additional Solana accounts derive distinct addresses', () async {
    final fixture = await _Fixture.create('solana-accounts');
    try {
      final wallet = await fixture.createWallet(curve: 'ed25519');
      final first = await fixture.client.accounts.create(
        name: 'Solana 1',
        wallet: wallet.id,
        type: 'solana',
      );
      final second = await fixture.client.accounts.create(
        name: 'Solana 2',
        wallet: wallet.id,
        type: 'solana',
      );

      expect(first.wallet, wallet.id);
      expect(second.wallet, wallet.id);
      expect(first.index, 0);
      expect(second.index, 1);
      expect(second.address, isNot(first.address));
    } finally {
      await fixture.dispose();
    }
  });

  test('Bitcoin-family formats honor their explicit network', () async {
    final fixture = await _Fixture.create('bitcoin-networks');
    try {
      final wallet = await fixture.createWallet(curve: 'secp256k1');
      final account = await fixture.client.accounts.create(
        name: 'Bitcoin',
        wallet: wallet.id,
        type: 'bitcoin',
      );
      final networks = (await fixture.client.networks.list(
        testNet: false,
      )).where((network) => network.type == NetworkType.bitcoin).toList();
      final expectedSymbols = {'BTC', 'BCH', 'DOGE', 'LTC'};
      final targets = networks
          .where((network) => expectedSymbols.contains(network.currencySymbol))
          .toList();
      expect(
        targets.map((network) => network.currencySymbol).toSet(),
        expectedSymbols,
      );

      final addresses = <String, String>{};
      for (final network in targets) {
        final result = await fixture.client.accounts.addressFormats(
          account.id,
          network: network.id,
        );
        expect(result.chainId, network.chainId);
        expect(result.formats, isNotEmpty);
        addresses[network.currencySymbol] = result.formats.first.address;
      }

      expect(addresses.values.toSet(), hasLength(expectedSymbols.length));
    } finally {
      await fixture.dispose();
    }
  });

  for (final (curve, type) in [
    ('ed25519', 'solana'),
    ('secp256k1', 'ethereum'),
  ]) {
    test(
      '$type old backup recreates later derived addresses through app account creation',
      () async {
        final source = await _Fixture.create('$type-old-backup-source');
        final target = await _Fixture.create('$type-old-backup-target');
        final sourceBackend = _Backend(source.client);
        final targetBackend = _Backend(target.client);
        final sourceMwa = MwaWalletBackend();
        final targetMwa = MwaWalletBackend();
        final sourceAccounts = AccountsService(sourceBackend, sourceMwa);
        final targetAccounts = AccountsService(targetBackend, targetMwa);
        try {
          for (final fixture in [source, target]) {
            final networks = await fixture.client.networks.list(testNet: false);
            final network = networks.firstWhere(
              (network) => type == 'solana'
                  ? network.type == NetworkType.solana
                  : network.type == NetworkType.evm && network.chainId == '1',
            );
            await fixture.client.networks.setCurrent(network.id);
          }
          final wallet = await source.createWallet(curve: curve);
          final root = await sourceAccounts.createAccount(
            walletId: wallet.id,
            name: 'Native account',
            type: type,
          );
          expect(root, isNotNull);
          expect(root!.index, 0);
          // The EVM wallet also has a Bitcoin backing account at index zero.
          // It must not affect the per-chain sequence used by Create Account.
          if (type == 'ethereum') {
            await source.client.accounts.create(
              wallet: wallet.id,
              name: 'Bitcoin backing',
              type: 'bitcoin',
              index: 0,
            );
          }
          final oldBackup = await sourceBackend.exportBackupJson(
            'first-password',
            walletIds: {wallet.id},
          );
          final laterAccounts = <Account>[];
          for (var i = 1; i <= 3; i++) {
            final account = await sourceAccounts.createAccount(
              walletId: wallet.id,
              name: 'Original name $i',
              type: type,
            );
            expect(account, isNotNull);
            expect(account!.index, i);
            laterAccounts.add(account);
          }
          final files = (jsonDecode(oldBackup) as List)
              .map((entry) => Map<String, String>.from(entry as Map))
              .toList();
          await target.client.wallets.restore(files);
          final initial = (await target.client.accounts.list(
            wallet: wallet.id,
          )).where((account) => account.type == type).toList();
          expect(initial, hasLength(1));
          expect(initial.single.address, root.address);

          for (final original in laterAccounts) {
            final recovered = await targetAccounts.createAccount(
              walletId: wallet.id,
              name: 'New name ${original.index}',
              type: type,
            );
            expect(recovered, isNotNull);
            expect(recovered!.wallet, original.wallet);
            expect(recovered.index, original.index);
            expect(recovered.path, original.path);
            expect(recovered.address, original.address);
            expect(recovered.name, 'New name ${original.index}');
          }
          final after = (await target.client.wallets.list()).single;
          expect(after.id, wallet.id);
          expect(after.pubkey, wallet.pubkey);
          expect(after.chaincode, wallet.chaincode);
          expect(after.gen, wallet.gen);
          final recoveredAccounts = (await target.client.accounts.list(
            wallet: wallet.id,
          )).where((account) => account.type == type).toList();
          expect(recoveredAccounts.map((account) => account.address).toSet(), {
            root.address,
            ...laterAccounts.map((account) => account.address),
          });
          final next = await targetAccounts.createAccount(
            walletId: wallet.id,
            name: 'Next new account',
            type: type,
          );
          expect(next!.index, 4);
          expect(
            recoveredAccounts.any((account) => account.address == next.address),
            isFalse,
          );

          await target.client.wallets.restore(files);
          final repeated = (await target.client.accounts.list(
            wallet: wallet.id,
          )).where((account) => account.type == type).toList();
          expect(repeated, hasLength(5));
          expect(
            repeated.map((account) => account.address).toSet(),
            hasLength(5),
          );
        } finally {
          sourceAccounts.dispose();
          targetAccounts.dispose();
          sourceMwa.dispose();
          targetMwa.dispose();
          sourceBackend.dispose();
          targetBackend.dispose();
          await target.dispose();
          await source.dispose();
        }
      },
    );

    test('$type backup restores derived accounts on a fresh device', () async {
      final source = await _Fixture.create('$type-backup-source');
      final target = await _Fixture.create('$type-backup-target');
      try {
        for (final fixture in [source, target]) {
          final networks = await fixture.client.networks.list(testNet: false);
          final network = networks.firstWhere(
            (network) => type == 'solana'
                ? network.type == NetworkType.solana
                : network.type == NetworkType.evm && network.chainId == '1',
          );
          await fixture.client.networks.setCurrent(network.id);
        }
        final wallet = await source.createWallet(curve: curve);
        final original = <Account>[];
        for (final index in [0, 2]) {
          original.add(
            await source.client.accounts.create(
              name: 'Account $index',
              wallet: wallet.id,
              type: type,
              index: index,
            ),
          );
        }
        final backup = await source.client.wallets.backup(wallet.id);
        await target.client.wallets.restore([
          for (final entry in backup)
            {'filename': entry.filename, 'data': entry.data},
        ]);
        final restoredWallet = (await target.client.wallets.list()).single;
        final restored = await target.client.accounts.list(
          wallet: restoredWallet.id,
        );
        restored.sort((a, b) => a.index.compareTo(b.index));
        expect(
          restored.map((a) => [a.type, a.index, a.path, a.name, a.address]),
          original.map((a) => [a.type, a.index, a.path, a.name, a.address]),
        );
        final next = await target.client.accounts.create(
          name: 'Next account',
          wallet: restoredWallet.id,
          type: type,
        );
        expect(next.index, 3);
        expect(original.every((a) => a.address != next.address), isTrue);
      } finally {
        await target.dispose();
        await source.dispose();
      }
    });
  }
}

class _Fixture {
  final Directory directory;
  final LibwalletClient client;

  const _Fixture(this.directory, this.client);

  static Future<_Fixture> create(String name) async {
    final directory = await Directory.systemTemp.createTemp('tibane-$name-');
    final client = LibwalletClient.initialize(
      directory.path,
      library: _openNativeLibrary(),
    );
    await client.ready;
    return _Fixture(directory, client);
  }

  Future<Wallet> createWallet({required String curve}) async {
    Wallet? wallet;
    await for (final event in client.wallets.create(
      name: 'Test wallet',
      curve: curve,
      keys: const [
        KeyDescription(type: 'Password', key: 'first-password'),
        KeyDescription(type: 'Password', key: 'second-password'),
        KeyDescription(type: 'Password', key: 'third-password'),
      ],
    )) {
      if (event case Complete(:final value)) wallet = value;
    }
    return wallet!;
  }

  Future<void> dispose() async {
    client.dispose();
    await directory.delete(recursive: true);
  }
}

DynamicLibrary _openNativeLibrary() {
  final nativeBuildDir = Directory(
    '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
  );
  final nativeBinary = nativeBuildDir.listSync().whereType<File>().singleWhere(
    (file) => file.path.endsWith('.dylib'),
  );
  return DynamicLibrary.open(nativeBinary.path);
}
