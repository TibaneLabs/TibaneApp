/// Wallet-creation decisions — pure helpers (Atonline-parity Phase 2, §5 / D5).
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
/// WITHOUT one (D5) is signed the same lockless way — the sign sheet collects
/// its two Password shares per transaction.
bool modeHasStoreKey(CreationMode mode) => mode == CreationMode.biometric;

/// How to persist a **freshly-minted StoreKey** (creation, rotate, 2FA
/// recovery, device-import) so custody stays consistent — the Atonline model:
///
/// - On a biometric device the StoreKey private is custodied **only** behind
///   `biometric_storage` (so every sign prompts), plus the D8 password blob for
///   OS-restore recovery. There is **no** no-auth keystore copy — [enrollBiometric]
///   is true, [osKeystoreCopy] false.
/// - Without biometric it falls back to the no-auth OS keystore copy (+ blob) —
///   [enrollBiometric] false, [osKeystoreCopy] true.
///
/// The invariant: `enrollBiometric == !osKeystoreCopy` — biometric custody and
/// a no-auth copy are mutually exclusive, so nothing ever bypasses the gate.
({bool enrollBiometric, bool osKeystoreCopy}) freshStoreKeyPersistPlan({
  required bool hasBiometric,
}) =>
    (enrollBiometric: hasBiometric, osKeystoreCopy: !hasBiometric);
