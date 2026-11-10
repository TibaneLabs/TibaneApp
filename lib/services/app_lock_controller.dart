import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLockBiometricKind { unavailable, face, other }

enum AppLockMode { off, biometric, passcode }

enum AppLockAuthentication { deviceOwner, biometricOnly, passcodeOnly }

enum AppLockFailure { loading, authentication, unavailable, saving }

abstract class AppLockAuthenticator {
  bool get supportsPasscodeOnly;
  Future<AppLockBiometricKind> availability();
  Future<bool> passcodeAvailable();
  Future<bool> authenticate(String reason, AppLockAuthentication policy);
  Future<void> cancel();
}

class DeviceAppLockAuthenticator implements AppLockAuthenticator {
  static const _passcode = MethodChannel(
    'net.tibane.tibaneapp/app-lock-passcode',
  );
  final _auth = LocalAuthentication();
  AppLockAuthentication? _activePolicy;

  @override
  bool get supportsPasscodeOnly => Platform.isIOS;

  @override
  Future<bool> passcodeAvailable() async =>
      supportsPasscodeOnly &&
      await _passcode.invokeMethod<bool>('available') == true;

  @override
  Future<AppLockBiometricKind> availability() async {
    try {
      if (!await _auth.canCheckBiometrics) {
        return AppLockBiometricKind.unavailable;
      }
      final types = await _auth.getAvailableBiometrics();
      if (types.isEmpty) return AppLockBiometricKind.unavailable;
      return Platform.isIOS && types.contains(BiometricType.face)
          ? AppLockBiometricKind.face
          : AppLockBiometricKind.other;
    } catch (_) {
      return AppLockBiometricKind.unavailable;
    }
  }

  @override
  Future<bool> authenticate(String reason, AppLockAuthentication policy) async {
    if (_activePolicy != null) return false;
    _activePolicy = policy;
    try {
      if (policy == AppLockAuthentication.passcodeOnly) {
        return supportsPasscodeOnly &&
            await _passcode.invokeMethod<bool>('authenticate', reason) == true;
      }
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: policy == AppLockAuthentication.biometricOnly,
      );
    } finally {
      _activePolicy = null;
    }
  }

  @override
  Future<void> cancel() async {
    if (_activePolicy == AppLockAuthentication.passcodeOnly) {
      await _passcode.invokeMethod<void>('cancel');
    } else if (_activePolicy != null) {
      await _auth.stopAuthentication();
    }
  }
}

/// A UI access gate only: no wallet credentials or signing permissions live here.
class AppLockController extends ChangeNotifier {
  AppLockController({
    AppLockAuthenticator? authenticator,
    Future<AppLockMode> Function()? readMode,
    Future<void> Function(AppLockMode)? writeMode,
  }) : _auth = authenticator ?? DeviceAppLockAuthenticator(),
       _readMode = readMode ?? _readPreference,
       _writeMode = writeMode ?? _writePreference;

  static const preferenceKey = 'app_lock_enabled_v1';
  final AppLockAuthenticator _auth;
  final Future<AppLockMode> Function() _readMode;
  final Future<void> Function(AppLockMode) _writeMode;
  bool _ready = false;
  bool _loading = false;
  AppLockMode _mode = AppLockMode.off;
  bool _locked = true;
  bool _shield = false;
  bool _foreground = true;
  bool _background = false;
  bool _busy = false;
  bool _disposed = false;
  int _epoch = 0;
  AppLockFailure? _failure;

  bool get ready => _ready;
  AppLockMode get mode => _mode;
  bool get enabled => _mode != AppLockMode.off;
  bool get supportsPasscodeOnly => _auth.supportsPasscodeOnly;
  bool get busy => _busy;
  bool get foreground => _foreground;
  bool get needsUnlock => _ready && enabled && _locked;
  bool get blocksContent => !_ready || (enabled && (_locked || _shield));
  bool get privacyOnly => _ready && enabled && !_locked && _shield;
  int get lockSession => _epoch;
  AppLockFailure? get failure => _failure;

  static Future<AppLockMode> _readPreference() async {
    final value = (await SharedPreferences.getInstance()).get(preferenceKey);
    return switch (value) {
      null || false => AppLockMode.off,
      'passcode' => AppLockMode.passcode,
      // Preserve existing biometric opt-ins and fail closed on unknown values.
      _ => AppLockMode.biometric,
    };
  }

  static Future<void> _writePreference(AppLockMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = mode == AppLockMode.passcode
        ? await preferences.setString(preferenceKey, mode.name)
        : await preferences.setBool(preferenceKey, mode != AppLockMode.off);
    if (!saved) {
      throw StateError('app_lock_preference_not_saved');
    }
  }

  Future<AppLockBiometricKind> availability() async {
    try {
      return await _auth.availability().timeout(const Duration(seconds: 5));
    } catch (_) {
      return AppLockBiometricKind.unavailable;
    }
  }

  Future<bool> passcodeAvailable() async {
    if (!supportsPasscodeOnly) return false;
    try {
      return await _auth.passcodeAvailable().timeout(
        const Duration(seconds: 5),
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> load() async {
    if (_loading || _disposed) return;
    _loading = true;
    _ready = false;
    _failure = null;
    notifyListeners();
    try {
      final value = await _readMode();
      if (_disposed) return;
      _mode = value;
      _locked = enabled;
      _ready = true;
      _epoch++;
    } catch (_) {
      if (!_disposed) _failure = AppLockFailure.loading;
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> _authenticate(String reason, AppLockAuthentication policy) =>
      _auth
          .authenticate(reason, policy)
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () {
              unawaited(_cancel());
              return false;
            },
          );

  Future<void> unlock(String reason) async {
    if (_disposed || !needsUnlock || _busy || !_foreground) return;
    final epoch = _epoch;
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      final ok = await _authenticate(
        reason,
        _mode == AppLockMode.passcode
            ? AppLockAuthentication.passcodeOnly
            : AppLockAuthentication.deviceOwner,
      );
      if (_disposed || epoch != _epoch || _background) return;
      if (ok) {
        _locked = false;
      } else {
        _failure = AppLockFailure.authentication;
      }
    } catch (_) {
      if (!_disposed && epoch == _epoch) {
        _failure = AppLockFailure.authentication;
      }
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> setMode(AppLockMode value, String reason) async {
    if (_disposed || !_ready || _busy || !_foreground || _locked) {
      return false;
    }
    if (_mode == value) return true;
    final epoch = _epoch;
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      final available = switch (value) {
        AppLockMode.off => true,
        AppLockMode.biometric =>
          await availability() != AppLockBiometricKind.unavailable,
        AppLockMode.passcode => await passcodeAvailable(),
      };
      if (_disposed || epoch != _epoch || _background) return false;
      if (!available) {
        _failure = AppLockFailure.unavailable;
        return false;
      }
      final policy =
          _mode == AppLockMode.passcode || value == AppLockMode.passcode
          ? AppLockAuthentication.passcodeOnly
          : value == AppLockMode.biometric
          ? AppLockAuthentication.biometricOnly
          : AppLockAuthentication.deviceOwner;
      final ok = await _authenticate(reason, policy);
      if (_disposed || epoch != _epoch || _background) return false;
      if (!ok) {
        _failure = AppLockFailure.authentication;
        return false;
      }
      try {
        await _writeMode(value);
      } catch (_) {
        _failure = AppLockFailure.saving;
        return false;
      }
      if (_disposed) return false;
      _mode = value;
      _locked = enabled && (_background || epoch != _epoch);
      return true;
    } catch (_) {
      if (!_disposed && epoch == _epoch) {
        _failure = AppLockFailure.authentication;
      }
      return false;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void handleLifecycle(AppLifecycleState state) {
    if (_disposed) return;
    _foreground = state == AppLifecycleState.resumed;
    _shield = !_foreground;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _background = true;
      _epoch++;
      if (enabled) _locked = true;
      _failure = null;
      if (_busy) unawaited(_cancel());
    } else if (state == AppLifecycleState.resumed) {
      _background = false;
    }
    notifyListeners();
  }

  Future<void> _cancel() async {
    try {
      await _auth.cancel();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    if (_busy) unawaited(_cancel());
    super.dispose();
  }
}
