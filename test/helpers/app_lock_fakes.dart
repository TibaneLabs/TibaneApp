import 'dart:async';

import 'package:tibaneapp/services/app_lock_controller.dart';

class FakeAppLockAuthenticator implements AppLockAuthenticator {
  AppLockBiometricKind kind = AppLockBiometricKind.face;
  bool result = true;
  bool throwsError = false;
  bool completeOnCancel = true;
  Completer<bool>? pending;
  int calls = 0;
  int cancels = 0;
  final policies = <bool>[];

  @override
  Future<AppLockBiometricKind> availability() async => kind;
  @override
  Future<bool> authenticate(
    String reason, {
    required bool biometricOnly,
  }) async {
    calls++;
    policies.add(biometricOnly);
    if (throwsError) throw StateError('Fixture authentication unavailable');
    return pending == null ? result : await pending!.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (completeOnCancel && pending != null && !pending!.isCompleted) {
      pending!.complete(false);
    }
  }
}
