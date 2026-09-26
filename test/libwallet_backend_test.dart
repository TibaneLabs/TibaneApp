import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';

import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

Wallet _walletWithKeys(
  List<WalletKey> keys, {
  String id = 'wallet-id',
  String curve = 'ed25519',
}) => Wallet(
  id: id,
  name: 'test',
  curve: curve,
  protocol: 'frost',
  threshold: 1,
  gen: 1,
  pubkey: '',
  chaincode: '',
  created: DateTime.utc(2026, 1, 1),
  modified: DateTime.utc(2026, 1, 1),
  keys: keys,
);

WalletKey _key({
  required String id,
  required String type,
  required String key,
}) => WalletKey(id: id, wallet: 'wallet-id', type: type, key: key, gen: 1);

Account _account({
  required String id,
  required String wallet,
  required String type,
}) => Account(
  id: id,
  wallet: wallet,
  name: '',
  index: 0,
  type: type,
  path: '',
  address: '',
  uri: '',
  pubkey: '',
  chaincode: '',
  created: DateTime.utc(2026, 1, 1),
  updated: DateTime.utc(2026, 1, 1),
);

void main() {
  group('defaultAccountTypesForCurve', () {
    test('ed25519 exposes Solana', () {
      expect(
        LibwalletBackend.defaultAccountTypesForCurve('ed25519'),
        equals(['solana']),
      );
    });

    test('secp256k1 exposes Ethereum; Bitcoin is a network context', () {
      expect(
        LibwalletBackend.defaultAccountTypesForCurve('secp256k1'),
        equals(['ethereum']),
      );
    });

    test('unknown curve exposes no default account types', () {
      expect(LibwalletBackend.defaultAccountTypesForCurve('unknown'), isEmpty);
    });
  });

  group('LibwalletBackend.buildReshareOldKeys', () {
    test(
      'recovery path (storeKeyPriv=null) omits StoreKey, keeps RemoteKey + Password',
      () {
        // Regression: the recovery flow exists precisely because this
        // device doesn't hold the StoreKey private. We must NOT pass
        // the wallet's stored StoreKey public (~44-byte X.509) where
        // libwallet expects the 64-byte private — that tripped the
        // opener's length check and aborted reshare before any TSS
        // round ran.
        final wallet = _walletWithKeys([
          _key(id: 'sk-id', type: 'StoreKey', key: 'STORE_PUBLIC_X509'),
          _key(id: 'rk-id', type: 'RemoteKey', key: 'OLD_REMOTE_SESSION'),
          _key(id: 'pw-id', type: 'Password', key: 'unused-server-side'),
        ]);

        final reshareOld = LibwalletBackend.buildReshareOldKeys(
          wallet: wallet,
          password: 'hunter2',
          storeKeyPriv: null,
          freshRemoteKeyResource: 'FRESH_REMOTE_SESSION',
        );

        expect(
          reshareOld.map((k) => k.type).toList(),
          equals(['RemoteKey', 'Password']),
        );
        expect(reshareOld[0].id, equals('rk-id'));
        expect(reshareOld[0].key, equals('FRESH_REMOTE_SESSION'));
        expect(reshareOld[1].id, equals('pw-id'));
        expect(reshareOld[1].key, equals('hunter2'));
      },
    );

    test(
      'happy path (storeKeyPriv set) includes all three shares with the private',
      () {
        final wallet = _walletWithKeys([
          _key(id: 'sk-id', type: 'StoreKey', key: 'STORE_PUBLIC_X509'),
          _key(id: 'rk-id', type: 'RemoteKey', key: 'OLD_REMOTE_SESSION'),
          _key(id: 'pw-id', type: 'Password', key: 'unused-server-side'),
        ]);

        final reshareOld = LibwalletBackend.buildReshareOldKeys(
          wallet: wallet,
          password: 'hunter2',
          storeKeyPriv: 'STORE_PRIVATE_64_BYTES',
          freshRemoteKeyResource: 'FRESH_REMOTE_SESSION',
        );

        expect(
          reshareOld.map((k) => k.type).toList(),
          equals(['StoreKey', 'RemoteKey', 'Password']),
        );
        expect(reshareOld[0].id, equals('sk-id'));
        expect(
          reshareOld[0].key,
          equals('STORE_PRIVATE_64_BYTES'),
          reason: 'must be the 64-byte private, not the wallet row public',
        );
        expect(reshareOld[1].id, equals('rk-id'));
        expect(reshareOld[1].key, equals('FRESH_REMOTE_SESSION'));
        expect(reshareOld[2].id, equals('pw-id'));
      },
    );

    test(
      'falls back to stored RemoteKey row when no fresh session supplied',
      () {
        final wallet = _walletWithKeys([
          _key(id: 'sk-id', type: 'StoreKey', key: 'STORE_PUBLIC_X509'),
          _key(id: 'rk-id', type: 'RemoteKey', key: 'OLD_REMOTE_SESSION'),
          _key(id: 'pw-id', type: 'Password', key: 'unused'),
        ]);

        final reshareOld = LibwalletBackend.buildReshareOldKeys(
          wallet: wallet,
          password: 'pw',
          storeKeyPriv: 'priv',
        );

        final remote = reshareOld.firstWhere((k) => k.type == 'RemoteKey');
        expect(remote.key, equals('OLD_REMOTE_SESSION'));
      },
    );

    test('omits RemoteKey entirely when wallet has no RemoteKey row', () {
      final wallet = _walletWithKeys([
        _key(id: 'sk-id', type: 'StoreKey', key: 'STORE_PUBLIC_X509'),
        _key(id: 'pw-id', type: 'Password', key: 'unused'),
      ]);

      final reshareOld = LibwalletBackend.buildReshareOldKeys(
        wallet: wallet,
        password: 'pw',
        storeKeyPriv: 'priv',
      );

      expect(
        reshareOld.map((k) => k.type).toList(),
        equals(['StoreKey', 'Password']),
      );
    });

    test('throws when wallet has no StoreKey row (existence check)', () {
      // The existence check is intentional: reshareNew always installs
      // a fresh StoreKey, so the wallet must already carry a StoreKey
      // row in the slot we're replacing. This is independent of
      // whether the local device holds the private.
      final wallet = _walletWithKeys([
        _key(id: 'rk-id', type: 'RemoteKey', key: 'OLD_REMOTE_SESSION'),
        _key(id: 'pw-id', type: 'Password', key: 'unused'),
      ]);

      expect(
        () => LibwalletBackend.buildReshareOldKeys(
          wallet: wallet,
          password: 'pw',
          storeKeyPriv: null,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when wallet has no Password row', () {
      final wallet = _walletWithKeys([
        _key(id: 'sk-id', type: 'StoreKey', key: 'STORE_PUBLIC_X509'),
        _key(id: 'rk-id', type: 'RemoteKey', key: 'OLD_REMOTE_SESSION'),
      ]);

      expect(
        () => LibwalletBackend.buildReshareOldKeys(
          wallet: wallet,
          password: 'pw',
          storeKeyPriv: 'priv',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('LibwalletBackend.planDefaultAccounts', () {
    final ed = _walletWithKeys([], id: 'sol-wallet', curve: 'ed25519');
    final secp = _walletWithKeys([], id: 'evm-wallet', curve: 'secp256k1');

    test('a wallet missing its default type is scheduled for creation', () {
      final plan = LibwalletBackend.planDefaultAccounts(
        accounts: const [],
        walletsById: {ed.id: ed, secp.id: secp},
        alreadyEnsured: const {},
      );
      expect(plan.toCreate[ed.id], ['solana']);
      expect(plan.toCreate[secp.id], ['ethereum']);
      expect(plan.ensured, isEmpty);
    });

    test('a wallet that already has its default type is ensured, not created', () {
      final plan = LibwalletBackend.planDefaultAccounts(
        accounts: [
          _account(id: 'a1', wallet: ed.id, type: 'solana'),
          _account(id: 'a2', wallet: secp.id, type: 'ethereum'),
        ],
        walletsById: {ed.id: ed, secp.id: secp},
        alreadyEnsured: const {},
      );
      expect(plan.toCreate, isEmpty);
      expect(plan.ensured, {ed.id, secp.id});
    });

    test('an already-ensured wallet is skipped even when the list looks partial',
        () {
      // Simulates a transiently-partial accounts.list(): the default row is
      // absent, but the persisted flag prevents a duplicate-creating backfill.
      final plan = LibwalletBackend.planDefaultAccounts(
        accounts: const [],
        walletsById: {secp.id: secp},
        alreadyEnsured: {secp.id},
      );
      expect(plan.toCreate, isEmpty);
      expect(plan.ensured, {secp.id});
    });

    test('a wallet whose curve has no default types is ignored', () {
      final unknown = _walletWithKeys([], id: 'x', curve: 'unknown');
      final plan = LibwalletBackend.planDefaultAccounts(
        accounts: const [],
        walletsById: {unknown.id: unknown},
        alreadyEnsured: const {},
      );
      expect(plan.toCreate, isEmpty);
      expect(plan.ensured, isEmpty);
    });
  });
}
