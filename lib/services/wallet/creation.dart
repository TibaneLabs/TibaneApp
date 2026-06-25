/// Wallet-creation decisions — pure helpers (Ellipx-parity Phase 2, §5 / D5).
///
/// Kept out of the backend so they're unit-testable without a device, a
/// libwallet client, or a biometric prompt (the existing pure-decision
/// pattern). The keygen ceremony, the biometric enrollment prompt, and the
/// at-rest writes are device-verified.
library;

/// Debug override: force the D5 (password-only) creation path even on a
/// biometric device, so the fallback can be exercised on the Seeker.
///   flutter run --dart-define=FORCE_UNSAFE=true
const bool kForceUnsafeCreation = bool.fromEnvironment('FORCE_UNSAFE');

/// The committee shape + StoreKey custody for a newly created wallet.
enum CreationMode {
  /// Biometric device: committee `[StoreKey, RemoteKey, Password]`; the
  /// StoreKey private is custodied behind `biometric_storage` (+ the D8
  /// password blob). No no-auth keystore copy.
  biometric,

  /// No biometric (D5 fallback): committee `[Password, Password, RemoteKey]`,
  /// threshold 1 — one typed password unlocks two shares (T+1) to sign, the
  /// RemoteKey stays for 2FA recovery. No StoreKey, nothing custodied at rest.
  /// Verified against the libwallet Go source: `multiCreate` needs ≥3 keys and
  /// imposes no uniqueness on key type, so two Password shares are accepted.
  passwordOnly,
}

/// Pick the creation mode. Biometric custody is used (and enforced) whenever
/// the device has biometrics, unless [forceUnsafe] (a debug override) is set.
CreationMode creationModeFor({
  required bool hasBiometric,
  bool forceUnsafe = false,
}) =>
    (hasBiometric && !forceUnsafe)
        ? CreationMode.biometric
        : CreationMode.passwordOnly;

/// The committee key types, in order, for a creation mode. Used to build the
/// `KeyDescription` list; unit-tested without libwallet.
List<String> creationKeyTypes(CreationMode mode) => switch (mode) {
      CreationMode.biometric => const ['StoreKey', 'RemoteKey', 'Password'],
      CreationMode.passwordOnly => const ['Password', 'Password', 'RemoteKey'],
    };

/// Whether a created wallet of this mode carries a StoreKey share. A wallet
/// WITHOUT one (D5) can only be signed via the per-transaction sign sheet —
/// the legacy `_signingKeys()` path expects a StoreKey — so it must route
/// through the sheet regardless of the lockless flag.
bool modeHasStoreKey(CreationMode mode) => mode == CreationMode.biometric;
