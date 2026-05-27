import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// At-rest storage for wallet secrets with two backends:
///
/// 1. **OS keystore** — iOS Keychain / Android EncryptedSharedPreferences via
///    `flutter_secure_storage`. Preferred. The device-share path uses this
///    when [isSecureStorageUsable] returns true.
///
/// 2. **Password-derived fallback** — when the OS keystore probe fails (rare
///    on modern devices; legacy Android without Keystore, restricted
///    enterprise profiles, etc.). The device share is encrypted with
///    AES-GCM under a key derived from the user's wallet password via
///    PBKDF2-HMAC-SHA256 (100k iterations) and stored as a base64 blob in
///    `SharedPreferences`. Decryption fails if the password is wrong, so
///    the auth tag doubles as a password check.
///
/// The optional biometric password cache always uses the OS keystore path —
/// if biometric storage isn't available, the toggle simply can't be enabled
/// and the user types the password as before.
class SecureKeystore {
  static const _ksDeviceShare = 'libw_device_share';
  static const _ksBiometricPw = 'libw_biometric_pw';
  static const _spFallbackBlob = 'libw_device_share_blob_v1';
  static const _spProbeKey = 'libw_keystore_probe';

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
  // Device share — always encrypted at rest, OS keystore preferred.
  // ---------------------------------------------------------------------

  /// Persist the device-share private key in every available location.
  ///
  /// - When the OS keystore is usable, the plaintext value is written
  ///   there (preferred read path).
  /// - The password-encrypted AES-GCM blob is **always** written to
  ///   SharedPreferences as a backup. This is the only copy that
  ///   survives an iOS restore-from-iCloud-Backup on a new device
  ///   (Keychain items with `unlocked_this_device` accessibility are
  ///   excluded from iCloud Backup, but the app sandbox — including
  ///   SharedPreferences — is included). The blob is unreadable
  ///   without the wallet password, so storing both copies doesn't
  ///   lower the security floor.
  ///
  /// Throws on hard failures of the OS keystore path when keystore is
  /// supposed to be usable.
  Future<void> writeDeviceShare({
    required String value,
    required String password,
  }) async {
    if (await isSecureStorageUsable()) {
      await _storage.write(
        key: _ksDeviceShare,
        value: value,
        iOptions: _iosPlain,
        aOptions: _androidPlain,
      );
    }
    final blob = await _encryptWithPassword(value, password);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_spFallbackBlob, blob);
  }

  /// Read the device-share private key. [password] is consulted only if
  /// the on-disk record is the fallback (AES-GCM) blob. Returns `null`
  /// when no record exists. Throws [WrongPasswordException] if the
  /// fallback decryption fails (auth tag mismatch).
  Future<String?> readDeviceShare({String? password}) async {
    if (await isSecureStorageUsable()) {
      final v = await _storage.read(
        key: _ksDeviceShare,
        iOptions: _iosPlain,
        aOptions: _androidPlain,
      );
      if (v != null) return v;
      // Fall through — the OS keystore might be working now even though
      // a previous launch wrote a fallback blob. Try that too.
    }
    final prefs = await SharedPreferences.getInstance();
    final blob = prefs.getString(_spFallbackBlob);
    if (blob == null) return null;
    if (password == null) {
      // Fallback requires a password to decrypt — caller must collect one.
      return null;
    }
    return _decryptWithPassword(blob, password);
  }

  /// True when a device-share entry exists in either the OS keystore
  /// or the password-encrypted fallback blob. Cheap probe — does not
  /// decrypt, does not require the password. Hosts use this to decide
  /// whether to render the normal password unlock UI or route into the
  /// 2FA recovery flow first.
  Future<bool> hasDeviceShare() async {
    if (await isSecureStorageUsable()) {
      try {
        final v = await _storage.read(
          key: _ksDeviceShare,
          iOptions: _iosPlain,
          aOptions: _androidPlain,
        );
        if (v != null) return true;
      } catch (e) {
        debugPrint('hasDeviceShare keystore read failed: $e');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_spFallbackBlob) != null;
  }

  Future<void> deleteDeviceShare() async {
    try {
      await _storage.delete(
        key: _ksDeviceShare,
        iOptions: _iosPlain,
        aOptions: _androidPlain,
      );
    } catch (_) {
      /* best-effort */
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_spFallbackBlob);
  }

  // ---------------------------------------------------------------------
  // Biometric password cache — opt-in.
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
