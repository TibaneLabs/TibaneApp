import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';

import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

Wallet _walletWithKeys(List<WalletKey> keys) => Wallet(
      id: 'wallet-id',
      name: 'test',
      curve: 'ed25519',
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
}) =>
    WalletKey(id: id, wallet: 'wallet-id', type: type, key: key, gen: 1);

void main() {
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

        expect(reshareOld.map((k) => k.type).toList(),
            equals(['RemoteKey', 'Password']));
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

        expect(reshareOld.map((k) => k.type).toList(),
            equals(['StoreKey', 'RemoteKey', 'Password']));
        expect(reshareOld[0].id, equals('sk-id'));
        expect(reshareOld[0].key, equals('STORE_PRIVATE_64_BYTES'),
            reason: 'must be the 64-byte private, not the wallet row public');
        expect(reshareOld[1].id, equals('rk-id'));
        expect(reshareOld[1].key, equals('FRESH_REMOTE_SESSION'));
        expect(reshareOld[2].id, equals('pw-id'));
      },
    );

    test('falls back to stored RemoteKey row when no fresh session supplied',
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
    });

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

      expect(reshareOld.map((k) => k.type).toList(),
          equals(['StoreKey', 'Password']));
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
}
