/// Existing-wallet migration decisions — pure helpers (Atonline-parity Phase 3,
/// §6 / D7). The biometric enrollment, the verify-read, the keystore deletes,
/// and the SharedPreferences flags are device-verified; only the decisions
/// live here so they're unit-testable.
library;

/// What the migrator should do with one wallet.
enum MigrationAction {
  /// Nothing to do: no StoreKey (a D5 wallet), already migrated, or no no-auth
  /// copy present (already biometric / blob-only / cross-device).
  skip,

  /// Move the StoreKey private from the no-auth keystore to biometric storage
  /// (verify-before-delete, keep the D8 blob).
  migrate,
}

/// Per-wallet migration decision. Pure: the caller supplies whether the wallet
/// has a StoreKey and whether a no-auth keystore copy of the share still
/// exists. A migrated wallet has no no-auth copy left (the migrator deletes it
/// after verify), so the absence of the copy is itself the "done" signal — no
/// separate per-wallet flag is needed.
MigrationAction migrationActionForWallet({
  required bool hasStoreKey,
  required bool hasNoAuthCopy,
}) {
  if (!hasStoreKey) return MigrationAction.skip; // D5 / password-only wallet
  if (!hasNoAuthCopy) return MigrationAction.skip; // nothing to move / done
  return MigrationAction.migrate;
}

/// Whether to show the eager one-time migration screen (D7). True only when the
/// device can custody behind biometric, there's at least one wallet still to
/// migrate, and the one-shot flag isn't set yet.
bool shouldMigrate({
  required bool alreadyMigrated,
  required bool hasWalletToMigrate,
  required bool biometricAvailable,
}) =>
    !alreadyMigrated && biometricAvailable && hasWalletToMigrate;
