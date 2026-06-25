import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet/creation.dart';

/// Phase 2a (Ellipx-parity) — pure StoreKey-custody decision at creation.
/// The biometric enrollment prompt and the at-rest writes are device-verified.
void main() {
  group('storeKeyStorageFor', () {
    test('biometric device → biometric custody', () {
      expect(storeKeyStorageFor(true), StoreKeyStorage.biometric);
    });

    test('no biometric → no-auth keystore (today\'s behavior)', () {
      expect(storeKeyStorageFor(false), StoreKeyStorage.noAuthKeystore);
    });
  });

  group('keepNoAuthKeystoreCopy', () {
    test('biometric wallet must NOT keep a no-auth copy', () {
      expect(keepNoAuthKeystoreCopy(StoreKeyStorage.biometric), isFalse);
    });

    test('no-biometric wallet keeps the no-auth copy', () {
      expect(keepNoAuthKeystoreCopy(StoreKeyStorage.noAuthKeystore), isTrue);
    });
  });
}
