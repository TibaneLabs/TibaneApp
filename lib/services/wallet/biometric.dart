import 'package:biometric_storage/biometric_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Biometric custody of a wallet's **StoreKey private key**.
///
/// This is the Atonline-parity custody layer (ported from
/// `atonline/lib/service/biometric.dart`). The StoreKey private is stored behind
/// a per-read biometric gate via `biometric_storage`, keyed by the StoreKey's
/// **public key** (Atonline convention: `setSecuredKey(priv, walletKey.key)`).
/// Reading it (`askSecuredKey`) triggers a FaceID / fingerprint prompt.
///
/// ## Storage-role split (Atonline-parity migration, see ATONLINE_PARITY §3.1)
///
/// Tibane intentionally uses **two** secure stores with distinct roles — keep
/// them from drifting:
///
///  * `Biometric` (this file, `biometric_storage`) → the **biometric-gated**
///    StoreKey private. Primary custody copy.
///  * [SecureKeystore] (`flutter_secure_storage` / SharedPreferences) → the
///    **non-biometric** at-rest fallback: the password-encrypted recovery blob
///    (kept per D8, survives OS restore) and the storage for no-biometric
///    (D5) wallets.
///
/// Because D8 keeps the password-encrypted blob, biometric here is a
/// convenience/UX gate over the StoreKey, **not** a hard second factor — the
/// security floor stays "password = full access". See §3.1 for the rationale.
///
/// > **Phase 0 scope:** this file only provides the primitive. The per-sign
/// > StoreKey read with its fallback chain (`biometric_storage` → no-auth
/// > keystore → password blob, §3.2) and the creation/migration wiring land in
/// > later phases — nothing calls into here yet.
///
/// Deliberate deviation from Atonline: Atonline's [askSecuredKey] carries a
/// `secured_key` legacy-migration branch (an older single-slot key bridged via
/// `SharedPreferencesService`). Tibane never shipped `biometric_storage`, so
/// there is no legacy to bridge and that branch is dropped.
class Biometric {
  static final BiometricStorage _bio = BiometricStorage();

  /// Whether this device can gate a secret behind biometrics — i.e. the
  /// hardware can check biometrics AND at least one biometric is enrolled.
  /// Used to enforce biometric custody when available (D5: enforce-if-available)
  /// and to decide the no-biometric fallback committee at creation.
  static Future<bool> hasBiometric() async {
    final auth = LocalAuthentication();
    final canCheck = await auth.canCheckBiometrics;
    final available = await auth.getAvailableBiometrics();
    return biometricAvailableFrom(canCheck, available);
  }

  /// Read the biometric-gated secret stored under [key] (the StoreKey public
  /// key). Triggers the platform biometric prompt. Returns `null` when no entry
  /// exists or the user cancels. Throws nothing on cancel — callers treat a
  /// `null` as "biometric copy unavailable" and fall through to the §3.2 chain.
  static Future<String?> askSecuredKey(String key) async {
    final storage = await _bio.getStorage(key);
    return storage.read();
  }

  /// Store [securedKey] (the StoreKey private) behind biometrics, keyed by
  /// [key] (the StoreKey public key).
  static Future<void> setSecuredKey(String securedKey, String key) async {
    final storage = await _bio.getStorage(key);
    await storage.write(securedKey);
  }

  /// Remove the biometric-gated secret under [key]. Best-effort.
  static Future<void> deleteSecuredKey(String key) async {
    try {
      final storage = await _bio.getStorage(key);
      await storage.delete();
    } catch (e) {
      debugPrint('Biometric.deleteSecuredKey($key) failed: $e');
    }
  }
}

/// Pure availability decision, extracted so it can be unit-tested without a
/// device (the plugin calls in [Biometric.hasBiometric] need a platform).
/// Mirrors Atonline: biometrics are usable iff the hardware can check them AND
/// at least one biometric is actually enrolled.
@visibleForTesting
bool biometricAvailableFrom(
  bool canCheckBiometrics,
  List<BiometricType> availableBiometrics,
) =>
    canCheckBiometrics && availableBiometrics.isNotEmpty;
