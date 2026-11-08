import 'dart:convert';
import 'dart:io';

import 'package:biometric_storage/biometric_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:libwallet/libwallet.dart' show SigningKey, Wallet;
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'signing.dart' show isSingleDeviceKeyWallet;
import 'wallet_export_format.dart' show isNormalMnemonicWallet;

enum NormalBiometricKind { unavailable, face, other }

bool supportsNormalWalletBiometrics(Wallet wallet) =>
    isNormalMnemonicWallet(wallet) || isSingleDeviceKeyWallet(wallet);

class NormalBiometricPrompt {
  const NormalBiometricPrompt(this.reason, this.cancel);
  final String reason;
  final String cancel;
}

class NormalBiometricUnavailable implements Exception {
  const NormalBiometricUnavailable();
}

/// These entries are separate from MPC device shares and never enter backups.
abstract class NormalBiometricVault {
  Future<NormalBiometricKind> availability();
  Future<String?> read(String name, NormalBiometricPrompt prompt);
  Future<void> write(String name, String secret, NormalBiometricPrompt prompt);
  Future<void> delete(String name);
  Future<bool> confirmOwner(String reason);
}

class DeviceNormalBiometricVault implements NormalBiometricVault {
  StorageFileInitOptions get _options => StorageFileInitOptions(
    authenticationRequired: true,
    androidBiometricOnly: true,
    darwinBiometricOnly: true,
  );

  PromptInfo _prompt(NormalBiometricPrompt p) => PromptInfo(
    androidPromptInfo: AndroidPromptInfo(
      title: p.reason,
      negativeButton: p.cancel,
    ),
    iosPromptInfo: IosPromptInfo(saveTitle: p.reason, accessTitle: p.reason),
    macOsPromptInfo: IosPromptInfo(saveTitle: p.reason, accessTitle: p.reason),
  );

  @override
  Future<NormalBiometricKind> availability() async {
    try {
      if (await BiometricStorage().canAuthenticate(options: _options) !=
          CanAuthenticateResponse.success) {
        return NormalBiometricKind.unavailable;
      }
      final auth = LocalAuthentication();
      final types = await auth.getAvailableBiometrics();
      if (!await auth.canCheckBiometrics || types.isEmpty) {
        return NormalBiometricKind.unavailable;
      }
      return Platform.isIOS && types.contains(BiometricType.face)
          ? NormalBiometricKind.face
          : NormalBiometricKind.other;
    } catch (_) {
      return NormalBiometricKind.unavailable;
    }
  }

  @override
  Future<String?> read(String name, NormalBiometricPrompt prompt) async {
    final file = await BiometricStorage().getStorage(name, options: _options);
    return file.read(promptInfo: _prompt(prompt));
  }

  @override
  Future<void> write(
    String name,
    String secret,
    NormalBiometricPrompt prompt,
  ) async {
    final file = await BiometricStorage().getStorage(name, options: _options);
    await file.write(secret, promptInfo: _prompt(prompt));
  }

  @override
  Future<void> delete(String name) async {
    final file = await BiometricStorage().getStorage(name, options: _options);
    await file.delete();
  }

  @override
  Future<bool> confirmOwner(String reason) async {
    try {
      return await LocalAuthentication().authenticate(localizedReason: reason);
    } catch (_) {
      return false;
    }
  }
}

class NormalWalletBiometrics {
  NormalWalletBiometrics({NormalBiometricVault? vault})
    : _vault = vault ?? DeviceNormalBiometricVault();

  final NormalBiometricVault _vault;
  static const _prefix = 'normal_wallet_biometric_v1_';
  int _generation = 0;

  String _preference(String walletId) =>
      '$_prefix${sha256.convert(utf8.encode(walletId))}';

  String _binding(Wallet wallet) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            wallet.id,
            wallet.protocol,
            wallet.gen,
            wallet.pubkey,
            wallet.keys.single.id,
            wallet.keys.single.gen,
            wallet.keys.single.type,
            wallet.keys.single.key,
          ]),
        ),
      )
      .toString();

  String _entry(String binding) => 'normal_signing_$binding';

  Future<NormalBiometricKind> availability() => _vault.availability();

  Future<bool> isEnabled(Wallet wallet) async {
    if (!supportsNormalWalletBiometrics(wallet)) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.get(_preference(wallet.id)) == _binding(wallet);
  }

  /// Callers verify Password credentials before enrollment. No credential is
  /// written to preferences, logs or the libwallet database.
  Future<void> enable(
    Map<Wallet, String> credentials,
    NormalBiometricPrompt prompt,
  ) async {
    final generation = _generation;
    if (credentials.isEmpty ||
        credentials.entries.any(
          (e) => !supportsNormalWalletBiometrics(e.key) || e.value.isEmpty,
        )) {
      throw const NormalBiometricUnavailable();
    }
    if (await availability() == NormalBiometricKind.unavailable ||
        generation != _generation) {
      throw const NormalBiometricUnavailable();
    }
    final added = <String, String>{};
    try {
      for (final entry in credentials.entries) {
        if (await isEnabled(entry.key)) continue;
        final binding = _binding(entry.key);
        added[entry.key.id] = binding;
        await _vault.write(_entry(binding), entry.value, prompt);
        final verified = await _vault.read(_entry(binding), prompt);
        if (verified != entry.value || generation != _generation) {
          throw const NormalBiometricUnavailable();
        }
      }
      final prefs = await SharedPreferences.getInstance();
      for (final entry in added.entries) {
        if (generation != _generation ||
            !await prefs.setString(_preference(entry.key), entry.value)) {
          throw const NormalBiometricUnavailable();
        }
      }
    } catch (_) {
      await forget(added.keys);
      for (final binding in added.values) {
        try {
          await _vault.delete(_entry(binding));
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<SigningKey?> readSigningKey(
    Wallet wallet,
    NormalBiometricPrompt prompt,
  ) async {
    if (!await isEnabled(wallet)) return null;
    final generation = _generation;
    final secret = await _vault.read(_entry(_binding(wallet)), prompt);
    if (secret == null ||
        secret.isEmpty ||
        generation != _generation ||
        !await isEnabled(wallet)) {
      return null;
    }
    final key = wallet.keys.single;
    return SigningKey(id: key.id, key: secret, type: key.type);
  }

  Future<bool> disable(Iterable<String> walletIds, String reason) async {
    if (!await _vault.confirmOwner(reason)) return false;
    await forget(walletIds);
    return true;
  }

  /// Also used on deletion, without reading or authenticating any secret.
  Future<void> forget(Iterable<String> walletIds) async {
    _generation++;
    final prefs = await SharedPreferences.getInstance();
    for (final id in walletIds) {
      await _erase(prefs, _preference(id));
    }
  }

  Future<void> clear() async {
    _generation++;
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where((key) => key.startsWith(_prefix))) {
      await _erase(prefs, key);
    }
  }

  Future<void> _erase(SharedPreferences prefs, String key) async {
    final binding = prefs.get(key);
    await prefs.remove(key);
    if (binding is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(binding)) {
      try {
        await _vault.delete(_entry(binding));
      } catch (_) {}
    }
  }
}
