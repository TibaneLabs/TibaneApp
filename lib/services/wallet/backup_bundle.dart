import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libwallet/libwallet.dart';

const walletGroupManifest = '__tibane_wallet_groups_v1.json';

class BackupBundle {
  BackupBundle(this.files, this.groups);
  final List<Map<String, String>> files;
  final Map<String, String> groups;

  factory BackupBundle.decode(String text) {
    if (text.length > 64 * 1024 * 1024) {
      throw const FormatException('Backup too large');
    }
    final parsed = jsonDecode(text);
    if (parsed is! List || parsed.isEmpty || parsed.length > 10000) {
      throw const FormatException('Invalid wallet backup');
    }
    final files = <Map<String, String>>[];
    final groups = <String, String>{};
    final names = <String>{};
    for (final entry in parsed) {
      if (entry is! Map ||
          entry['filename'] is! String ||
          entry['data'] is! String) {
        throw const FormatException('Invalid backup entry');
      }
      final name = entry['filename'] as String;
      final data = entry['data'] as String;
      if (name.isEmpty ||
          name.startsWith('/') ||
          name.contains('\\') ||
          name.split('/').any((part) => part == '..' || part == '.') ||
          !names.add(name)) {
        throw const FormatException('Invalid backup filename');
      }
      if (name == walletGroupManifest) {
        final map = jsonDecode(data);
        if (map is! Map ||
            map.entries.any((e) => e.key is! String || e.value is! String)) {
          throw const FormatException('Invalid wallet group manifest');
        }
        groups.addAll(Map<String, String>.from(map));
      } else {
        files.add({'filename': name, 'data': data});
      }
    }
    if (files.isEmpty) {
      throw const FormatException('Backup contains no wallets');
    }
    return BackupBundle(files, groups);
  }
}

class BackupRestoreResult {
  BackupRestoreResult(this.wallet, this.account, this.addedIds, this.groups);
  final Wallet wallet;
  final Account account;
  final Set<String> addedIds;
  final Map<String, String> groups;
}

class BackupRollbackIncomplete implements Exception {
  const BackupRollbackIncomplete();

  @override
  String toString() => 'backup_rollback_incomplete';
}

/// Authenticate the entire bundle in a disposable store BEFORE touching the
/// live database. Existing wallet IDs are never overwritten by an old backup.
Future<BackupRestoreResult> restoreValidatedBackup({
  required LibwalletClient client,
  required BackupBundle bundle,
  required String password,
  required Future<LibwalletClient> Function(String path) createValidationClient,
  required Future<void> Function(LibwalletClient, Wallet, String)
  verifyPassword,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'tibane-backup-validation-',
  );
  LibwalletClient? staged;
  final added = <String>{};
  String? previousAccount;
  try {
    staged = await createValidationClient(directory.path);
    await staged.ready;
    await staged.wallets.restore(bundle.files);
    final wallets = await staged.wallets.list();
    if (wallets.isEmpty) {
      throw const FormatException('Backup contains no wallets');
    }
    for (final wallet in wallets) {
      if (wallet.curve != 'ed25519' && wallet.curve != 'secp256k1') {
        throw StateError('Unsupported wallet curve');
      }
      if (!wallet.keys.any((key) => key.isPassword)) {
        throw StateError('private_key_wallet_backup_unavailable');
      }
      await verifyPassword(staged, wallet, password);
      final accounts = (await staged.accounts.list(
        wallet: wallet.id,
      )).where((a) => a.wallet == wallet.id).toList();
      if (accounts.isEmpty) {
        await staged.accounts.create(
          name: wallet.curve == 'ed25519' ? 'Solana' : 'Ethereum',
          wallet: wallet.id,
          type: wallet.curve == 'ed25519' ? 'solana' : 'ethereum',
          index: 0,
        );
      }
    }
    final before = {
      for (final wallet in await client.wallets.list()) wallet.id: wallet,
    };
    try {
      previousAccount = (await client.accounts.getCurrent()).id;
    } catch (_) {}
    final commit = <Map<String, String>>[];
    for (final wallet in wallets) {
      final existing = before[wallet.id];
      if (existing != null) {
        if (existing.pubkey != wallet.pubkey ||
            existing.curve != wallet.curve) {
          throw StateError('Backup wallet conflicts with an existing wallet');
        }
        continue;
      }
      added.add(wallet.id);
      commit.addAll(
        (await staged.wallets.backup(
          wallet.id,
        )).map((f) => Map<String, String>.from(f.toJson())),
      );
    }
    if (commit.isNotEmpty) await client.wallets.restore(commit);
    final ids = wallets.map((w) => w.id).toSet();
    final liveWallets = (await client.wallets.list())
        .where((w) => ids.contains(w.id))
        .toList();
    if (liveWallets.length != ids.length) {
      throw StateError('Incomplete wallet restore');
    }
    liveWallets.sort(
      (a, b) => (a.curve == 'ed25519' ? 0 : 1).compareTo(
        b.curve == 'ed25519' ? 0 : 1,
      ),
    );
    final wallet = liveWallets.first;
    final accounts = (await client.accounts.list(wallet: wallet.id))
        .where(
          (a) =>
              a.wallet == wallet.id &&
              a.address.isNotEmpty &&
              a.address != 'N/A',
        )
        .toList();
    if (accounts.isEmpty) {
      throw StateError('Restored wallet has no usable account');
    }
    final account = accounts.firstWhere(
      (a) => a.type == (wallet.curve == 'ed25519' ? 'solana' : 'ethereum'),
      orElse: () => accounts.first,
    );
    return BackupRestoreResult(wallet, account, added, {
      for (final entry in bundle.groups.entries)
        if (ids.contains(entry.key) && ids.contains(entry.value))
          entry.key: entry.value,
    });
  } catch (_) {
    var cleanupFailed = false;
    for (final id in added) {
      try {
        await client.wallets.delete(id);
      } catch (_) {
        cleanupFailed = true;
      }
    }
    if (previousAccount != null) {
      try {
        await client.accounts.setCurrent(previousAccount);
      } catch (_) {
        cleanupFailed = true;
      }
    }
    if (cleanupFailed) throw const BackupRollbackIncomplete();
    rethrow;
  } finally {
    staged?.dispose();
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // A staging cleanup failure must not turn a committed restore into
      // an apparent failure, which could encourage an unsafe retry.
      debugPrint('Backup validation temporary-store cleanup failed');
    }
  }
}
