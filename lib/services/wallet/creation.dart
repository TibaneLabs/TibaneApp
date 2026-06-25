/// Wallet-creation decisions — pure helpers (Ellipx-parity Phase 2, §5).
///
/// Kept out of the backend so they're unit-testable without a device, a
/// libwallet client, or a biometric prompt (the existing pure-decision
/// pattern). The keygen ceremony, the biometric enrollment prompt, and the
/// at-rest writes are device-verified.
library;

/// Where a freshly created wallet's StoreKey private key is custodied.
enum StoreKeyStorage {
  /// Device has biometrics: store the StoreKey behind `biometric_storage`
  /// (custody) + the password-encrypted blob (D8 recovery). No no-auth copy.
  biometric,

  /// No biometrics on this device: keep today's behavior — the StoreKey in the
  /// no-auth OS keystore + the password blob. (Phase 2b replaces this branch
  /// with the D5 password-only committee.)
  noAuthKeystore,
}

/// Pick the StoreKey custody for creation from biometric availability.
/// `hasBiometric == true` ⇒ biometric custody (enforced); otherwise the
/// no-auth keystore (today's behavior).
StoreKeyStorage storeKeyStorageFor(bool hasBiometric) =>
    hasBiometric ? StoreKeyStorage.biometric : StoreKeyStorage.noAuthKeystore;

/// Whether to also write the no-auth OS-keystore copy of the StoreKey at
/// creation. False for biometric wallets — keeping a no-auth copy would defeat
/// the biometric gate (the StoreKey would be readable with no auth).
bool keepNoAuthKeystoreCopy(StoreKeyStorage storage) =>
    storage == StoreKeyStorage.noAuthKeystore;
