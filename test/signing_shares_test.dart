import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show SigningKey, Wallet, WalletKey;
import 'package:tibaneapp/services/wallet/signing.dart';

/// Phase 1 (Atonline-parity) — pure share-counting rules for per-transaction
/// signing. The sheet UI, biometric/keystore reads, and the real libwallet
/// signature are device-verified, not covered here.

WalletKey _key(String type) =>
    WalletKey(id: 'id-$type', wallet: 'w1', type: type, key: 'k-$type', gen: 0);

Wallet _wallet({required int threshold, required List<String> keyTypes}) => Wallet(
      id: 'w1',
      name: 'Test',
      curve: 'ed25519',
      threshold: threshold,
      gen: 0,
      pubkey: '',
      chaincode: '',
      created: DateTime.fromMillisecondsSinceEpoch(0),
      modified: DateTime.fromMillisecondsSinceEpoch(0),
      keys: keyTypes.map(_key).toList(),
    );

void main() {
  group('requiredSigningShares', () {
    test('is threshold + 1 (S1: t+1 parties to sign)', () {
      expect(requiredSigningShares(1), 2); // standard 2-of-3
      expect(requiredSigningShares(0), 1);
      expect(requiredSigningShares(2), 3);
    });
  });

  group('collectibleSigningKeys', () {
    test('keeps StoreKey + Password, drops the dormant RemoteKey', () {
      final keys = [_key('StoreKey'), _key('RemoteKey'), _key('Password')];
      final got = collectibleSigningKeys(keys).map((k) => k.type).toList();
      expect(got, ['StoreKey', 'Password']);
    });

    test('drops RemoteKey-only wallets to nothing collectible', () {
      expect(collectibleSigningKeys([_key('RemoteKey')]), isEmpty);
    });
  });

  group('canAssembleThreshold', () {
    test('standard StoreKey+RemoteKey+Password, threshold 1 → signable', () {
      final w = _wallet(threshold: 1, keyTypes: ['StoreKey', 'RemoteKey', 'Password']);
      expect(canAssembleThreshold(w), isTrue); // 2 collectible >= 2 required
    });

    test('Password + RemoteKey, threshold 1 → unsignable on device', () {
      // Only 1 collectible share (Password); RemoteKey is dormant. Needs 2.
      final w = _wallet(threshold: 1, keyTypes: ['Password', 'RemoteKey']);
      expect(canAssembleThreshold(w), isFalse);
    });

    test('multi-password committee (D5), threshold 1 → signable from password', () {
      final w = _wallet(threshold: 1, keyTypes: ['Password', 'Password', 'RemoteKey']);
      expect(canAssembleThreshold(w), isTrue); // 2 Password shares >= 2 required
    });
  });

  group('signSheetReady', () {
    test('ready once collected reaches threshold + 1', () {
      expect(signSheetReady(0, 1), isFalse);
      expect(signSheetReady(1, 1), isFalse);
      expect(signSheetReady(2, 1), isTrue);
      expect(signSheetReady(3, 1), isTrue);
    });
  });

  group('useSignSheetFor', () {
    test('in-app -> sheet (signing is always per-transaction now)', () {
      expect(useSignSheetFor(isInApp: true), isTrue);
    });

    test('MWA -> no sheet (Seed Vault signs via its own auth)', () {
      expect(useSignSheetFor(isInApp: false), isFalse);
    });
  });

  group('managementCredsFrom (6D-1)', () {
    SigningKey sk(String type, String key) =>
        SigningKey(id: 'id-$type', key: key, type: type);

    test('standard 2-of-3: extracts StoreKey priv + Password', () {
      final creds = managementCredsFrom([
        sk('StoreKey', 'store-priv'),
        sk('Password', 'hunter2'),
      ]);
      expect(creds.password, 'hunter2');
      expect(creds.storeKeyPriv, 'store-priv');
    });

    test('D5 (password-only) committee: password set, storeKeyPriv null', () {
      final creds = managementCredsFrom([
        sk('Password', 'pw'),
        sk('Password', 'pw'),
      ]);
      expect(creds.password, 'pw');
      expect(creds.storeKeyPriv, isNull);
    });

    test('empty / no password collected -> password null', () {
      expect(managementCredsFrom(const []).password, isNull);
      expect(managementCredsFrom([sk('StoreKey', 'p')]).password, isNull);
    });

    test('takes the first of each type', () {
      final creds = managementCredsFrom([
        sk('Password', 'first'),
        sk('Password', 'second'),
        sk('StoreKey', 'sk1'),
        sk('StoreKey', 'sk2'),
      ]);
      expect(creds.password, 'first');
      expect(creds.storeKeyPriv, 'sk1');
    });
  });

  group('effectiveManagementCreds (6D-2)', () {
    test('per-op values win over the cache', () {
      final creds = effectiveManagementCreds(
        paramPassword: 'new-pw',
        paramStoreKeyPriv: 'new-sk',
        cachedPassword: 'cached-pw',
        cachedStoreKeyPriv: 'cached-sk',
      );
      expect(creds.password, 'new-pw');
      expect(creds.storeKeyPriv, 'new-sk');
    });

    test('falls back to the cached session when params are null (old path)', () {
      final creds = effectiveManagementCreds(
        cachedPassword: 'cached-pw',
        cachedStoreKeyPriv: 'cached-sk',
      );
      expect(creds.password, 'cached-pw');
      expect(creds.storeKeyPriv, 'cached-sk');
    });

    test('resolves each field independently', () {
      // Password from the sheet, StoreKey from the cache (and vice versa).
      final a = effectiveManagementCreds(
        paramPassword: 'p',
        cachedStoreKeyPriv: 'sk',
      );
      expect(a.password, 'p');
      expect(a.storeKeyPriv, 'sk');

      final b = effectiveManagementCreds(
        paramStoreKeyPriv: 'sk2',
        cachedPassword: 'p2',
      );
      expect(b.password, 'p2');
      expect(b.storeKeyPriv, 'sk2');
    });

    test('all null when neither source has creds (op refused)', () {
      final creds = effectiveManagementCreds();
      expect(creds.password, isNull);
      expect(creds.storeKeyPriv, isNull);
    });

    test('password-only wallet: password resolves, storeKeyPriv stays null', () {
      final creds = effectiveManagementCreds(
        paramPassword: 'pw',
        // No StoreKey anywhere — D5 committee.
      );
      expect(creds.password, 'pw');
      expect(creds.storeKeyPriv, isNull);
    });
  });

  group('buildManagementReshareCommittee (6D-2 reshare recipe)', () {
    // Regression guard for the `could not find key id=` bug: OLD descriptors
    // must carry the WalletKey id, OLD must be exactly the 2 held shares (no
    // RemoteKey), OLD StoreKey key must be the secret, NEW StoreKey key the
    // public.
    final c = buildManagementReshareCommittee(
      oldStoreKeyId: 'wkey-store',
      storeSecret: 'device-secret-64b',
      oldPasswordKeyId: 'wkey-pass',
      oldPassword: 'oldpw',
      newStorePublic: 'store-pub',
      newRemoteKey: 'crws-fresh:crwsv-new',
      newPassword: 'newpw',
    );

    test('OLD is exactly the two held shares (StoreKey + Password, no RemoteKey)',
        () {
      expect(c.oldKeys.length, 2);
      expect(c.oldKeys.map((k) => k.type), ['StoreKey', 'Password']);
      expect(c.oldKeys.any((k) => k.type == 'RemoteKey'), isFalse);
    });

    test('OLD descriptors carry their WalletKey id (the missing-id bug)', () {
      expect(c.oldKeys[0].id, 'wkey-store');
      expect(c.oldKeys[1].id, 'wkey-pass');
    });

    test('OLD StoreKey key is the device SECRET, Password key is the raw pw', () {
      expect(c.oldKeys[0].key, 'device-secret-64b');
      expect(c.oldKeys[1].key, 'oldpw');
    });

    test('NEW is the full 3-share committee in order', () {
      expect(c.newKeys.map((k) => k.type), ['StoreKey', 'RemoteKey', 'Password']);
    });

    test('NEW StoreKey key is the PUBLIC; RemoteKey is the FRESH session', () {
      expect(c.newKeys[0].key, 'store-pub');
      expect(c.newKeys[0].id, isNull);
      // RemoteKey must be the fresh crws- session from RemoteKey:validate —
      // not '' and not a wkey- id (that timed out on setGeneratedKey).
      expect(c.newKeys[1].key, 'crws-fresh:crwsv-new');
      expect(c.newKeys[2].key, 'newpw');
    });

    test('rotation shape: fresh public in NEW, unchanged password both sides',
        () {
      final r = buildManagementReshareCommittee(
        oldStoreKeyId: 'wkey-store',
        storeSecret: 'old-secret',
        oldPasswordKeyId: 'wkey-pass',
        oldPassword: 'pw',
        newStorePublic: 'FRESH-pub',
        newRemoteKey: 'crws-fresh',
        newPassword: 'pw', // rotate keeps the password
      );
      expect(r.oldKeys[0].key, 'old-secret'); // authorize with current secret
      expect(r.newKeys[0].key, 'FRESH-pub'); // move to the fresh keypair
      expect(r.newKeys[1].key, 'crws-fresh'); // fresh remote session
      expect(r.oldKeys[1].key, 'pw');
      expect(r.newKeys[2].key, 'pw');
    });
  });
}
