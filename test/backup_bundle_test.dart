import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/backup_bundle.dart';
import 'package:tibaneapp/utils/wallet_error.dart';

Wallet _wallet(String id) => Wallet(
  id: id,
  name: id,
  curve: 'ed25519',
  threshold: 1,
  gen: 0,
  pubkey: id,
  chaincode: '',
  created: DateTime(2026),
  modified: DateTime(2026),
  keys: [
    WalletKey(
      id: '$id-password',
      wallet: id,
      type: 'Password',
      key: '',
      gen: 0,
    ),
  ],
);

class _Wallets implements WalletApi {
  _Wallets({required this.staged});
  final bool staged;
  final deleted = <String>[];
  @override
  Future<List<Wallet>> list() async =>
      staged ? [_wallet('a'), _wallet('b')] : [];
  @override
  Future<Map<String, dynamic>> restore(List<Map<String, String>> files) async {
    if (!staged) throw StateError('fixture partial restore');
    return {};
  }

  @override
  Future<List<WalletBackupEntry>> backup(String id) async => [
    WalletBackupEntry(filename: '$id.json', data: 'fixture'),
  ];
  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    if (id == 'a') throw StateError('fixture cleanup failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Accounts implements AccountApi {
  @override
  Future<List<Account>> list({String? wallet, String? type}) async => [
    Account(
      id: 'account-$wallet',
      wallet: wallet!,
      name: 'Test',
      index: 0,
      type: 'solana',
      path: '',
      address: 'fixture',
      uri: '',
      pubkey: '',
      chaincode: '',
      created: DateTime(2026),
      updated: DateTime(2026),
    ),
  ];
  @override
  Future<Account> getCurrent() async =>
      throw StateError('No current fixture account');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  _Client({required bool staged}) : wallets = _Wallets(staged: staged);
  @override
  final _Wallets wallets;
  @override
  final accounts = _Accounts();
  @override
  Future<void> get ready async {}
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('backup rejects traversal, absolute paths and duplicate filenames', () {
    for (final name in ['../wallet.json', '/wallet.json', 'a/../b', r'a\b']) {
      expect(
        () => BackupBundle.decode(
          jsonEncode([
            {'filename': name, 'data': 'fixture'},
          ]),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => BackupBundle.decode(
        jsonEncode([
          {'filename': 'a.json', 'data': 'fixture'},
          {'filename': 'a.json', 'data': 'other'},
        ]),
      ),
      throwsFormatException,
    );
  });

  test(
    'rollback attempts every added wallet even when the first cleanup fails',
    () async {
      final client = _Client(staged: false);
      await expectLater(
        restoreValidatedBackup(
          client: client,
          bundle: BackupBundle([
            {'filename': 'fixture.json', 'data': 'fixture'},
          ], {}),
          password: 'fixture-password',
          createValidationClient: (_) async => _Client(staged: true),
          verifyPassword: (_, _, _) async {},
        ),
        throwsA(
          isA<BackupRollbackIncomplete>().having(
            (e) => WalletError.from(e).key,
            'friendly error',
            WalletErrorKey.backupRollbackIncomplete,
          ),
        ),
      );
      expect(client.wallets.deleted, ['a', 'b']);
    },
  );
}
