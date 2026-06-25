import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// At-rest storage for wallet secrets. The **device share** is keyed PER
/// WALLET (schema v2) so the app can hold several wallets at once without
/// one wallet's share clobbering another's. Two backends per entry:
///
/// 1. **OS keystore** — iOS Keychain / Android EncryptedSharedPreferences via
///    `flutter_secure_storage`. Preferred read path when usable.
/// 2. **Password-derived fallback** — the device share encrypted with
///    AES-GCM under a key derived from the wallet password (PBKDF2-HMAC-
///    SHA256, 100k iterations), stored as a base64 blob in SharedPreferences.
///    This is the only copy that survives an iOS restore-from-iCloud-Backup
///    on a new device (Keychain `unlocked_this_device` items are excluded
///    from iCloud Backup; the app sandbox / SharedPreferences is included).
///
/// Schema v2 key layout (per wallet id):
///   OS keystore : `libw_device_share_<walletId>`
///   fallback    : `libw_device_share_blob_v1_<walletId>`
/// The legacy single-slot keys (`libw_device_share`,
/// `libw_device_share_blob_v1`) are migrated once by [migrateToPerWalletV2]
/// to the active wallet's id (verify-before-delete, idempotent).
///
/// The biometric password cache stays single-slot for now (one active
/// wallet at a time); it becomes per-wallet when wallet-switching lands.
class SecureKeystore {
  // --- legacy schema-v1 single-slot keys (migration source only) ---
  static const _legacyDeviceShare = 'libw_device_share';
  static const _legacyFallbackBlob = 'libw_device_share_blob_v1';

  // --- biometric (unchanged, still single-slot) ---
  static const _ksBiometricPw = 'libw_biometric_pw';

  static const _spProbeKey = 'libw_keystore_probe';

  /// Set once [migrateToPerWalletV2] has completed. Gates the migration and
  /// the legacy-fallback read path.
  static const _spSchemaV2 = 'libw_schema_v2';

  // --- per-wallet key builders (schema v2) ---
  static String _dsKey(String walletId) => 'libw_device_share_$walletId';
  static String _blobKey(String walletId) =>
      'libw_device_share_blob_v1_$walletId';

  /// iOS: biometric-or-passcode gate, this-device-only (no iCloud).
  /// Android: enforces biometric on read/write via Keystore.
  static const IOSOptions _iosBio = IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
    accessControlFlags: [AccessControlFlag.userPresence],
  );
  static const AndroidOptions _androidBio = AndroidOptions();

  /// Non-biometric OS keystore options — encryption at rest, no user
  /// presence required. Used for the device share when [isSecureStorageUsable].
  static const IOSOptions _iosPlain = IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
  );
  static const AndroidOptions _androidPlain = AndroidOptions();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final Random _rng = Random.secure();

  bool? _cachedUsable;

  /// Probe the OS keystore once and cache the result. Hosts that intend
  /// to skip the password-fallback path (e.g. agent setups) can call this
  /// at startup and refuse to create a wallet if it returns false.
  Future<bool> isSecureStorageUsable() async {
    if (_cachedUsable != null) return _cachedUsable!;
    try {
      await _storage.write(
        key: _spProbeKey,
        value: 'ok',
        iOptions: _iosPlain,
        aOptions: _androidPlain,
      );
      final back = await _storage.read(
        key: _spProbeKey,
        iOptions: _iosPlain,
        aOptions: _androidPlain,
      );
      await _storage.delete(
        key: _spProbeKey,
        iOptions: _iosPlain,
        aOptions: _androidPlain,
      );
      _cachedUsable = back == 'ok';
    } catch (e) {
      debugPrint('SecureKeystore probe failed: $e');
      _cachedUsable = false;
    }
    return _cachedUsable!;
  }

  // ---------------------------------------------------------------------
  // Device share — per wallet, always encrypted at rest, OS keystore preferred.
  // ---------------------------------------------------------------------

  /// Persist [walletId]'s device-share private key. Writes the no-auth
  /// OS-keystore copy (when usable and [osKeystoreCopy]) and ALWAYS the
  /// password-encrypted fallback blob. Both copies are keyed by [walletId],
  /// so writing one wallet's share never disturbs another's.
  ///
  /// [osKeystoreCopy] defaults true (the historical behavior). Pass `false`
  /// for biometric-custody wallets (Ellipx-parity §3.1): the StoreKey private
  /// lives behind biometric via [Biometric] + this password blob (D8 recovery
  /// copy), and must NOT also sit in the no-auth keystore — that would defeat
  /// the biometric gate.
  Future<void> writeDeviceShare({
    required String walletId,
    required String value,
    required String password,
    bool osKeystoreCopy = true,
  }) async {
    if (osKeystoreCopy && await isSecureStorageUsable()) {
      await _storage.write(
        key: _dsKey(walletId),
        value: value,
        iOptions: _iosPlain,
        aOptions: _androidPlain,
      );
    }
    final blob = await _encryptWithPassword(value, password);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_blobKey(walletId), blob);
  }

  /// Read [walletId]'s device-share private key. [password] is consulted
  /// only if the record is the fallback (AES-GCM) blob. Returns `null` when
  /// no record exists. Throws [WrongPasswordException] if fallback
  /// decryption fails (auth-tag mismatch).
  Future<String?> readDeviceShare({
    required String walletId,
    String? password,
  }) async {
    if (await isSecureStorageUsable()) {
      final v = await _storage.read(
        key: _dsKey(walletId),
        iOptions: _iosPlain,
        aOptions: _androidPlain,
      );
      if (v != null) return v;
    }
    final prefs = await SharedPreferences.getInstance();
    var blob = prefs.getString(_blobKey(walletId));
    // Pre-migration safety: until v2 lands, fall back to the legacy
    // single-slot blob (it belongs to the active wallet).
    if (blob == null && prefs.getBool(_spSchemaV2) != true) {
      blob = prefs.getString(_legacyFallbackBlob);
    }
    if (blob == null) return null;
    if (password == null) {
      // Fallback requires a password to decrypt — caller must collect one.
      return null;
    }
    return _decryptWithPassword(blob, password);
  }

  /// True when a device-share entry exists for [walletId] in either backend.
  /// Cheap probe — does not decrypt, does not require the password.
  Future<bool> hasDeviceShare(String walletId) async {
    if (await isSecureStorageUsable()) {
      try {
        final v = await _storage.read(
          key: _dsKey(walletId),
          iOptions: _iosPlain,
          aOptions: _androidPlain,
        );
        if (v != null) return true;
      } catch (e) {
        debugPrint('hasDeviceShare keystore read failed: $e');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_blobKey(walletId)) != null) return true;
    if (prefs.getBool(_spSchemaV2) != true &&
        prefs.getString(_legacyFallbackBlob) != null) {
      return true;
    }
    return false;
  }

  Future<void> deleteDeviceShare(String walletId) async {
    try {
      await _storage.delete(
        key: _dsKey(walletId),
        iOptions: _iosPlain,
        aOptions: _androidPlain,
      );
    } catch (_) {
      /* best-effort */
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_blobKey(walletId));
  }

  /// True when the **no-auth OS-keystore** copy of [walletId]'s device share
  /// exists. Cheap existence probe for the biometric migration (§6.3) — does
  /// not consult the password blob.
  Future<bool> hasNoAuthKeystoreCopy(String walletId) async {
    if (!await isSecureStorageUsable()) return false;
    try {
      final v = await _storage.read(
        key: _dsKey(walletId),
        iOptions: _iosPlain,
        aOptions: _androidPlain,
      );
      return v != null;
    } catch (e) {
      debugPrint('hasNoAuthKeystoreCopy($walletId): $e');
      return false;
    }
  }

  /// Delete ONLY the no-auth OS-keystore copy of [walletId]'s device share,
  /// leaving the password-encrypted blob intact (D8). Used by the biometric
  /// migration AFTER the StoreKey has been re-stored behind biometric and
  /// verified (verify-before-delete, §6.3).
  Future<void> deleteNoAuthKeystoreCopy(String walletId) async {
    try {
      await _storage.delete(
        key: _dsKey(walletId),
        iOptions: _iosPlain,
        aOptions: _androidPlain,
      );
    } catch (e) {
      debugPrint('deleteNoAuthKeystoreCopy($walletId): $e');
    }
  }

  // ---------------------------------------------------------------------
  // Migration: single-slot (v1) → per-wallet (v2). Idempotent, verify-
  // before-delete. Runs once from tryRestore, before any unlock.
  // ---------------------------------------------------------------------

  /// Move the legacy single-slot device share (OS keystore + fallback blob)
  /// to [activeWalletId]'s per-wallet keys. Safe to call on every launch:
  /// it no-ops once `libw_schema_v2` is set. If a copy can't be verified the
  /// flag is NOT set and the legacy entries are NOT deleted, so the next
  /// launch retries cleanly — no data loss on a crashed/partial run.
  ///
  /// Only the device share is migrated here. The legacy plaintext
  /// (`libw_store_priv`) is handled by the unlock path; the biometric cache
  /// stays single-slot for now.
  Future<void> migrateToPerWalletV2(String? activeWalletId) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_spSchemaV2) == true) return; // idempotent gate
    if (activeWalletId == null) {
      // Fresh install / no wallet — nothing to migrate.
      await prefs.setBool(_spSchemaV2, true);
      return;
    }

    var verified = true;
    final usable = await isSecureStorageUsable();

    // 1. OS-keystore device share.
    if (usable) {
      try {
        final legacy = await _storage.read(
          key: _legacyDeviceShare,
          iOptions: _iosPlain,
          aOptions: _androidPlain,
        );
        if (legacy != null) {
          await _storage.write(
            key: _dsKey(activeWalletId),
            value: legacy,
            iOptions: _iosPlain,
            aOptions: _androidPlain,
          );
          final back = await _storage.read(
            key: _dsKey(activeWalletId),
            iOptions: _iosPlain,
            aOptions: _androidPlain,
          );
          if (back != legacy) verified = false;
        }
      } catch (e) {
        debugPrint('[migration] OS device-share copy failed: $e');
        verified = false;
      }
    }

    // 2. Password-encrypted fallback blob (the iCloud-surviving copy).
    final legacyBlob = prefs.getString(_legacyFallbackBlob);
    if (legacyBlob != null) {
      await prefs.setString(_blobKey(activeWalletId), legacyBlob);
      if (prefs.getString(_blobKey(activeWalletId)) != legacyBlob) {
        verified = false;
      }
    }

    if (!verified) {
      debugPrint(
        '[migration] v2 incomplete — legacy entries kept, retry next launch',
      );
      return; // flag NOT set, nothing deleted
    }

    // All copies verified → delete the legacy device-share entries.
    if (usable) {
      try {
        await _storage.delete(
          key: _legacyDeviceShare,
          iOptions: _iosPlain,
          aOptions: _androidPlain,
        );
      } catch (_) {
        /* best-effort */
      }
    }
    await prefs.remove(_legacyFallbackBlob);
    await prefs.setBool(_spSchemaV2, true);
    debugPrint('[migration] v2 per-wallet device share complete');
  }

  // ---------------------------------------------------------------------
  // Biometric password cache — opt-in, single-slot (per-wallet in Phase 2).
  // ---------------------------------------------------------------------

  /// Save the wallet password into the biometric-gated keystore.
  /// Subsequent [readBiometricPassword] calls trigger FaceID/TouchID/
  /// fingerprint. Throws if biometric storage isn't available — the host
  /// should hide the toggle when [isBiometricAvailable] returns false.
  Future<void> writeBiometricPassword(String password) async {
    await _storage.write(
      key: _ksBiometricPw,
      value: password,
      iOptions: _iosBio,
      aOptions: _androidBio,
    );
  }

  /// Read the cached password. On iOS / Android this triggers the
  /// platform biometric prompt. Returns null if the user cancels, or if
  /// no entry exists.
  Future<String?> readBiometricPassword() async {
    try {
      return await _storage.read(
        key: _ksBiometricPw,
        iOptions: _iosBio,
        aOptions: _androidBio,
      );
    } catch (e) {
      // User cancelled biometric or no entry. Don't surface as an error.
      debugPrint('readBiometricPassword: $e');
      return null;
    }
  }

  Future<void> deleteBiometricPassword() async {
    try {
      await _storage.delete(
        key: _ksBiometricPw,
        iOptions: _iosBio,
        aOptions: _androidBio,
      );
    } catch (_) {
      /* best-effort */
    }
  }

  /// Best-effort probe for whether the biometric path can be used. Right
  /// now we equate "secure storage usable" with "biometric usable" since
  /// flutter_secure_storage handles graceful biometric degradation
  /// internally on Android and iOS rejects biometric reads at use-time.
  Future<bool> isBiometricAvailable() => isSecureStorageUsable();

  // ---------------------------------------------------------------------
  // Password-derived AES-GCM fallback.
  // ---------------------------------------------------------------------

  /// Format: base64(salt(16) || nonce(12) || ciphertext || mac(16)).
  Future<String> _encryptWithPassword(String plaintext, String password) async {
    final salt = _randomBytes(16);
    final key = await _deriveKey(password, salt);
    final algo = AesGcm.with256bits();
    final nonce = _randomBytes(12);
    final box = await algo.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    final mac = box.mac.bytes;
    final out = BytesBuilder()
      ..add(salt)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(mac);
    return base64Encode(out.toBytes());
  }

  Future<String> _decryptWithPassword(String blob, String password) async {
    final bytes = base64Decode(blob);
    if (bytes.length < 16 + 12 + 16) {
      throw const FormatException('Encrypted device-share blob is truncated');
    }
    final salt = bytes.sublist(0, 16);
    final nonce = bytes.sublist(16, 28);
    final mac = bytes.sublist(bytes.length - 16);
    final cipher = bytes.sublist(28, bytes.length - 16);
    final key = await _deriveKey(password, salt);
    final algo = AesGcm.with256bits();
    try {
      final plain = await algo.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(key),
      );
      return utf8.decode(plain);
    } on SecretBoxAuthenticationError {
      throw WrongPasswordException();
    }
  }

  Future<List<int>> _deriveKey(String password, List<int> salt) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    final secret = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return secret.extractBytes();
  }

  Uint8List _randomBytes(int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }
}

class WrongPasswordException implements Exception {
  const WrongPasswordException();

  @override
  String toString() => 'WrongPasswordException: wrong wallet password';
}
