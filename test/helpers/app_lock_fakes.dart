import 'dart:async';

import 'package:tibaneapp/services/app_lock_controller.dart';

class FakeAppLockAuthenticator implements AppLockAuthenticator {
  @override
  bool supportsPasscodeOnly = true;
  bool hasPasscode = true;
  AppLockBiometricKind kind = AppLockBiometricKind.face;
  bool result = true;
  bool throwsError = false;
  bool completeOnCancel = true;
  Completer<bool>? pending;
  int calls = 0;
  int cancels = 0;
  final policies = <AppLockAuthentication>[];

  @override
  Future<AppLockBiometricKind> availability() async => kind;
  @override
  Future<bool> passcodeAvailable() async => hasPasscode;
  @override
  Future<bool> authenticate(String reason, AppLockAuthentication policy) async {
    calls++;
    policies.add(policy);
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
