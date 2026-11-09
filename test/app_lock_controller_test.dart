import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/app_lock_controller.dart';

import 'helpers/app_lock_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('malformed configuration locks rather than exposing the app', () async {
    SharedPreferences.setMockInitialValues({
      AppLockController.preferenceKey: 'unexpected',
    });
    final lock = AppLockController(authenticator: FakeAppLockAuthenticator());
    addTearDown(lock.dispose);
    await lock.load();
    expect(lock.needsUnlock, isTrue);
  });

  testWidgets('an unresponsive OS prompt times out without unlocking', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      AppLockController.preferenceKey: true,
    });
    final auth = FakeAppLockAuthenticator()..pending = Completer<bool>();
    final lock = AppLockController(authenticator: auth);
    await lock.load();
    final pending = lock.unlock('Fixture unlock');
    await tester.pump(const Duration(seconds: 61));
    await pending;
    expect(lock.needsUnlock, isTrue);
    expect(lock.busy, isFalse);
    expect(lock.failure, AppLockFailure.authentication);
    expect(auth.cancels, 1);
    lock.dispose();
  });

  test(
    'hidden until preference loads; default is off and no wallet is involved',
    () async {
      final auth = FakeAppLockAuthenticator();
      final lock = AppLockController(authenticator: auth);
      addTearDown(lock.dispose);
      expect(lock.blocksContent, isTrue);
      await lock.load();
      expect(lock.ready, isTrue);
      expect(lock.enabled, isFalse);
      expect(lock.blocksContent, isFalse);
      expect(auth.calls, 0);
    },
  );

  test(
    'cold start with enabled preference never restores an unlocked session',
    () async {
      SharedPreferences.setMockInitialValues({
        AppLockController.preferenceKey: true,
      });
      final lock = AppLockController(authenticator: FakeAppLockAuthenticator());
      addTearDown(lock.dispose);
      await lock.load();
      expect(lock.mode, AppLockMode.biometric);
      expect(lock.needsUnlock, isTrue);
      expect(lock.blocksContent, isTrue);
      await lock.unlock('Fixture unlock');
      expect(lock.blocksContent, isFalse);
      final restarted = AppLockController(
        authenticator: FakeAppLockAuthenticator(),
      );
      addTearDown(restarted.dispose);
      await restarted.load();
      expect(restarted.blocksContent, isTrue);
    },
  );

  test('enabling verifies biometrics and stores only a boolean', () async {
    final auth = FakeAppLockAuthenticator();
    final lock = AppLockController(authenticator: auth);
    addTearDown(lock.dispose);
    await lock.load();
    expect(await lock.setMode(AppLockMode.biometric, 'Fixture enable'), isTrue);
    expect(auth.policies, [AppLockAuthentication.biometricOnly]);
    expect(lock.blocksContent, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {AppLockController.preferenceKey});
    expect(prefs.getBool(AppLockController.preferenceKey), isTrue);
  });

  test('failed or cancelled enable never turns the lock on', () async {
    final auth = FakeAppLockAuthenticator()..result = false;
    final lock = AppLockController(authenticator: auth);
    addTearDown(lock.dispose);
    await lock.load();
    expect(
      await lock.setMode(AppLockMode.biometric, 'Fixture enable'),
      isFalse,
    );
    expect(lock.enabled, isFalse);
    expect(lock.failure, AppLockFailure.authentication);
    auth.throwsError = true;
    expect(
      await lock.setMode(AppLockMode.biometric, 'Fixture enable'),
      isFalse,
    );
    expect(lock.enabled, isFalse);
  });

  test('unavailable biometrics cannot enable a new lock', () async {
    final auth = FakeAppLockAuthenticator()
      ..kind = AppLockBiometricKind.unavailable;
    final lock = AppLockController(authenticator: auth);
    addTearDown(lock.dispose);
    await lock.load();
    expect(
      await lock.setMode(AppLockMode.biometric, 'Fixture enable'),
      isFalse,
    );
    expect(lock.enabled, isFalse);
    expect(auth.calls, 0);
  });

  test(
    'disabling requires owner authentication and permits device-passcode fallback',
    () async {
      SharedPreferences.setMockInitialValues({
        AppLockController.preferenceKey: true,
      });
      final auth = FakeAppLockAuthenticator();
      final lock = AppLockController(authenticator: auth);
      addTearDown(lock.dispose);
      await lock.load();
      await lock.unlock('Fixture unlock');
      expect(auth.policies, [AppLockAuthentication.deviceOwner]);
      auth.result = false;
      expect(await lock.setMode(AppLockMode.off, 'Fixture disable'), isFalse);
      expect(lock.enabled, isTrue);
      auth.result = true;
      auth.kind = AppLockBiometricKind.unavailable;
      expect(await lock.setMode(AppLockMode.off, 'Fixture disable'), isTrue);
      expect(lock.enabled, isFalse);
      expect(auth.policies, List.filled(3, AppLockAuthentication.deviceOwner));
    },
  );

  test(
    'background locks immediately; inactive alone only covers the content',
    () async {
      SharedPreferences.setMockInitialValues({
        AppLockController.preferenceKey: true,
      });
      final lock = AppLockController(authenticator: FakeAppLockAuthenticator());
      addTearDown(lock.dispose);
      await lock.load();
      await lock.unlock('Fixture unlock');
      lock.handleLifecycle(AppLifecycleState.inactive);
      expect(lock.blocksContent, isTrue);
      expect(lock.privacyOnly, isTrue);
      lock.handleLifecycle(AppLifecycleState.resumed);
      expect(lock.blocksContent, isFalse);
      lock.handleLifecycle(AppLifecycleState.paused);
      expect(lock.needsUnlock, isTrue);
      lock.handleLifecycle(AppLifecycleState.resumed);
      expect(lock.blocksContent, isTrue);
    },
  );

  test(
    'late authentication cannot unlock after the app entered background',
    () async {
      SharedPreferences.setMockInitialValues({
        AppLockController.preferenceKey: true,
      });
      final auth = FakeAppLockAuthenticator()
        ..pending = Completer<bool>()
        ..completeOnCancel = false;
      final lock = AppLockController(authenticator: auth);
      addTearDown(lock.dispose);
      await lock.load();
      final pending = lock.unlock('Fixture unlock');
      lock.handleLifecycle(AppLifecycleState.paused);
      lock.handleLifecycle(AppLifecycleState.resumed);
      auth.pending!.complete(true);
      await pending;
      expect(lock.blocksContent, isTrue);
      expect(auth.cancels, 1);
    },
  );

  test(
    'system biometric inactive/resumed events do not invalidate a valid unlock',
    () async {
      SharedPreferences.setMockInitialValues({
        AppLockController.preferenceKey: true,
      });
      final auth = FakeAppLockAuthenticator()..pending = Completer<bool>();
      final lock = AppLockController(authenticator: auth);
      addTearDown(lock.dispose);
      await lock.load();
      final pending = lock.unlock('Fixture unlock');
      lock.handleLifecycle(AppLifecycleState.inactive);
      lock.handleLifecycle(AppLifecycleState.resumed);
      auth.pending!.complete(true);
      await pending;
      expect(lock.blocksContent, isFalse);
      expect(auth.calls, 1);
      expect(auth.cancels, 0);
    },
  );

  test(
    'backgrounding during opt-in cancels it without persisting the setting',
    () async {
      final auth = FakeAppLockAuthenticator()..pending = Completer<bool>();
      final lock = AppLockController(authenticator: auth);
      addTearDown(lock.dispose);
      await lock.load();
      final pending = lock.setMode(AppLockMode.biometric, 'Fixture enable');
      await Future<void>.delayed(Duration.zero);
      lock.handleLifecycle(AppLifecycleState.paused);
      expect(await pending, isFalse);
      expect(lock.enabled, isFalse);
    },
  );

  test('loading failure hides content and can be retried', () async {
    var fail = true;
    final lock = AppLockController(
      readMode: () async {
        if (fail) throw StateError('Fixture storage failure');
        return AppLockMode.biometric;
      },
      authenticator: FakeAppLockAuthenticator(),
    );
    addTearDown(lock.dispose);
    await lock.load();
    expect(lock.ready, isFalse);
    expect(lock.blocksContent, isTrue);
    expect(lock.failure, AppLockFailure.loading);
    fail = false;
    await lock.load();
    expect(lock.needsUnlock, isTrue);
  });

  test('backgrounding while opt-in is saved locks the new session', () async {
    final saving = Completer<void>();
    final startedSaving = Completer<void>();
    final lock = AppLockController(
      authenticator: FakeAppLockAuthenticator(),
      writeMode: (_) {
        startedSaving.complete();
        return saving.future;
      },
    );
    addTearDown(lock.dispose);
    await lock.load();
    final pending = lock.setMode(AppLockMode.biometric, 'Fixture enable');
    await startedSaving.future;
    lock.handleLifecycle(AppLifecycleState.paused);
    lock.handleLifecycle(AppLifecycleState.resumed);
    saving.complete();
    expect(await pending, isTrue);
    expect(lock.enabled, isTrue);
    expect(lock.needsUnlock, isTrue);
  });

  test('saving failure preserves the previous security policy', () async {
    final lock = AppLockController(
      authenticator: FakeAppLockAuthenticator(),
      writeMode: (_) async => throw StateError('Fixture write failed'),
    );
    addTearDown(lock.dispose);
    await lock.load();
    expect(
      await lock.setMode(AppLockMode.biometric, 'Fixture enable'),
      isFalse,
    );
    expect(lock.enabled, isFalse);
    expect(lock.failure, AppLockFailure.saving);
  });

  test('overlapping unlock requests never open multiple OS prompts', () async {
    SharedPreferences.setMockInitialValues({
      AppLockController.preferenceKey: true,
    });
    final auth = FakeAppLockAuthenticator()..pending = Completer<bool>();
    final lock = AppLockController(authenticator: auth);
    addTearDown(lock.dispose);
    await lock.load();
    final first = lock.unlock('Fixture unlock');
    await lock.unlock('Duplicate fixture');
    expect(auth.calls, 1);
    auth.pending!.complete(false);
    await first;
    expect(lock.needsUnlock, isTrue);
  });

  test('passcode mode works without biometrics and survives restart', () async {
    final auth = FakeAppLockAuthenticator()
      ..kind = AppLockBiometricKind.unavailable;
    final lock = AppLockController(authenticator: auth);
    addTearDown(lock.dispose);
    await lock.load();
    expect(await lock.setMode(AppLockMode.passcode, 'Fixture enable'), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {AppLockController.preferenceKey});
    expect(prefs.getString(AppLockController.preferenceKey), 'passcode');
    final restarted = AppLockController(authenticator: auth);
    addTearDown(restarted.dispose);
    await restarted.load();
    expect(restarted.mode, AppLockMode.passcode);
    expect(restarted.needsUnlock, isTrue);
    auth.result = false;
    await restarted.unlock('Fixture cancel');
    expect(restarted.blocksContent, isTrue);
    auth.result = true;
    await restarted.unlock('Fixture unlock');
    expect(restarted.blocksContent, isFalse);
    expect(auth.policies, List.filled(3, AppLockAuthentication.passcodeOnly));
  });

  test('passcode mode cannot be enabled without a device passcode', () async {
    final auth = FakeAppLockAuthenticator()..hasPasscode = false;
    final lock = AppLockController(authenticator: auth);
    addTearDown(lock.dispose);
    await lock.load();
    expect(await lock.setMode(AppLockMode.passcode, 'Fixture enable'), isFalse);
    expect(lock.mode, AppLockMode.off);
    expect(lock.failure, AppLockFailure.unavailable);
    expect(auth.calls, 0);
  });

  test(
    'changing away from passcode mode still requires the passcode',
    () async {
      SharedPreferences.setMockInitialValues({
        AppLockController.preferenceKey: 'passcode',
      });
      final auth = FakeAppLockAuthenticator();
      final lock = AppLockController(authenticator: auth);
      addTearDown(lock.dispose);
      await lock.load();
      expect(await lock.setMode(AppLockMode.off, 'Fixture disable'), isFalse);
      await lock.unlock('Fixture unlock');
      auth.result = false;
      expect(await lock.setMode(AppLockMode.off, 'Fixture disable'), isFalse);
      expect(lock.mode, AppLockMode.passcode);
      auth.result = true;
      expect(
        await lock.setMode(AppLockMode.biometric, 'Fixture change'),
        isTrue,
      );
      expect(lock.mode, AppLockMode.biometric);
      expect(auth.policies, List.filled(3, AppLockAuthentication.passcodeOnly));
    },
  );

  test(
    'switching to passcode only verifies that policy before saving',
    () async {
      SharedPreferences.setMockInitialValues({
        AppLockController.preferenceKey: true,
      });
      final auth = FakeAppLockAuthenticator();
      final lock = AppLockController(authenticator: auth);
      addTearDown(lock.dispose);
      await lock.load();
      await lock.unlock('Fixture unlock');
      auth.result = false;
      expect(
        await lock.setMode(AppLockMode.passcode, 'Fixture change'),
        isFalse,
      );
      expect(lock.mode, AppLockMode.biometric);
      expect(auth.policies, [
        AppLockAuthentication.deviceOwner,
        AppLockAuthentication.passcodeOnly,
      ]);
    },
  );
}
