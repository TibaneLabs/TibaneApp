import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show Wallet, WalletKey;
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
    test('MWA always takes the legacy path', () {
      expect(
        useSignSheetFor(isInApp: false, lockless: true, walletRequiresSheet: true),
        isFalse,
      );
    });

    test('in-app + lockless on -> sheet', () {
      expect(
        useSignSheetFor(isInApp: true, lockless: true, walletRequiresSheet: false),
        isTrue,
      );
    });

    test('in-app + no StoreKey (D5) -> sheet even with lockless off', () {
      expect(
        useSignSheetFor(isInApp: true, lockless: false, walletRequiresSheet: true),
        isTrue,
      );
    });

    test('in-app + lockless off + has StoreKey -> legacy path', () {
      expect(
        useSignSheetFor(isInApp: true, lockless: false, walletRequiresSheet: false),
        isFalse,
      );
    });
  });
}
