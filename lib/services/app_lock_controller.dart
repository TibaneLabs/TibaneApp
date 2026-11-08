import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLockBiometricKind { unavailable, face, other }

enum AppLockFailure { loading, authentication, unavailable, saving }

abstract class AppLockAuthenticator {
  Future<AppLockBiometricKind> availability();
  Future<bool> authenticate(String reason, {required bool biometricOnly});
  Future<void> cancel();
}

class DeviceAppLockAuthenticator implements AppLockAuthenticator {
  final _auth = LocalAuthentication();

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
  Future<bool> authenticate(String reason, {required bool biometricOnly}) =>
      _auth.authenticate(localizedReason: reason, biometricOnly: biometricOnly);

  @override
  Future<void> cancel() async {
    await _auth.stopAuthentication();
  }
}

/// A UI access gate only: no wallet credentials or signing permissions live here.
class AppLockController extends ChangeNotifier {
  AppLockController({
    AppLockAuthenticator? authenticator,
    Future<bool> Function()? readEnabled,
    Future<void> Function(bool)? writeEnabled,
  }) : _auth = authenticator ?? DeviceAppLockAuthenticator(),
       _readEnabled = readEnabled ?? _readPreference,
       _writeEnabled = writeEnabled ?? _writePreference;

  static const preferenceKey = 'app_lock_enabled_v1';
  final AppLockAuthenticator _auth;
  final Future<bool> Function() _readEnabled;
  final Future<void> Function(bool) _writeEnabled;
  bool _ready = false;
  bool _loading = false;
  bool _enabled = false;
  bool _locked = true;
  bool _shield = false;
  bool _foreground = true;
  bool _background = false;
  bool _busy = false;
  bool _disposed = false;
  int _epoch = 0;
  AppLockFailure? _failure;

  bool get ready => _ready;
  bool get enabled => _enabled;
  bool get busy => _busy;
  bool get foreground => _foreground;
  bool get needsUnlock => _ready && _enabled && _locked;
  bool get blocksContent => !_ready || (_enabled && (_locked || _shield));
  bool get privacyOnly => _ready && _enabled && !_locked && _shield;
  int get lockSession => _epoch;
  AppLockFailure? get failure => _failure;

  static Future<bool> _readPreference() async {
    final value = (await SharedPreferences.getInstance()).get(preferenceKey);
    // Malformed settings must not turn a previously enabled lock off.
    return value != null && value != false;
  }

  static Future<void> _writePreference(bool value) async {
    if (!await (await SharedPreferences.getInstance()).setBool(
      preferenceKey,
      value,
    )) {
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

  Future<void> load() async {
    if (_loading || _disposed) return;
    _loading = true;
    _ready = false;
    _failure = null;
    notifyListeners();
    try {
      final value = await _readEnabled();
      if (_disposed) return;
      _enabled = value;
      _locked = value;
      _ready = true;
      _epoch++;
    } catch (_) {
      if (!_disposed) _failure = AppLockFailure.loading;
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> _authenticate(String reason, {required bool biometricOnly}) =>
      _auth
          .authenticate(reason, biometricOnly: biometricOnly)
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
      final ok = await _authenticate(reason, biometricOnly: false);
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

  Future<bool> setEnabled(bool value, String reason) async {
    if (_disposed || !_ready || _busy || !_foreground) return false;
    if (_enabled == value) return true;
    final epoch = _epoch;
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      if (value && await availability() == AppLockBiometricKind.unavailable) {
        _failure = AppLockFailure.unavailable;
        return false;
      }
      if (_disposed || epoch != _epoch || _background) return false;
      final ok = await _authenticate(reason, biometricOnly: value);
      if (_disposed || epoch != _epoch || _background) return false;
      if (!ok) {
        _failure = AppLockFailure.authentication;
        return false;
      }
      try {
        await _writeEnabled(value);
      } catch (_) {
        _failure = AppLockFailure.saving;
        return false;
      }
      if (_disposed) return false;
      _enabled = value;
      _locked = value && (_background || epoch != _epoch);
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
      if (_enabled) _locked = true;
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
