import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet/migration.dart';

/// Phase 3a (Ellipx-parity) — pure migration decisions (§6 / D7). The biometric
/// enrollment, verify-read, keystore deletes, and flags are device-verified.
void main() {
  group('migrationActionForWallet', () {
    test('migrates a StoreKey wallet that still has a no-auth copy', () {
      expect(
        migrationActionForWallet(hasStoreKey: true, hasNoAuthCopy: true),
        MigrationAction.migrate,
      );
    });

    test('skips a D5 (no StoreKey) wallet', () {
      expect(
        migrationActionForWallet(hasStoreKey: false, hasNoAuthCopy: false),
        MigrationAction.skip,
      );
    });

    test('skips when there is no no-auth copy (already migrated / biometric)',
        () {
      expect(
        migrationActionForWallet(hasStoreKey: true, hasNoAuthCopy: false),
        MigrationAction.skip,
      );
    });
  });

  group('shouldMigrate', () {
    test('true: not migrated, has a wallet to migrate, biometric available', () {
      expect(
        shouldMigrate(
          alreadyMigrated: false,
          hasWalletToMigrate: true,
          biometricAvailable: true,
        ),
        isTrue,
      );
    });

    test('false once the one-shot flag is set', () {
      expect(
        shouldMigrate(
          alreadyMigrated: true,
          hasWalletToMigrate: true,
          biometricAvailable: true,
        ),
        isFalse,
      );
    });

    test('false with no biometric (migration waits until it is available)', () {
      expect(
        shouldMigrate(
          alreadyMigrated: false,
          hasWalletToMigrate: true,
          biometricAvailable: false,
        ),
        isFalse,
      );
    });

    test('false when nothing needs migrating', () {
      expect(
        shouldMigrate(
          alreadyMigrated: false,
          hasWalletToMigrate: false,
          biometricAvailable: true,
        ),
        isFalse,
      );
    });
  });
}
