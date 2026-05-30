import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/secure_keystore.dart';

/// Phase 2 unit tests. The full `switchWallet` flow needs a live libwallet
/// client (on-device), so the routing decision is extracted into the pure
/// [LibwalletBackend.planWalletSwitch] and tested exhaustively here, plus a
/// keystore-level check that creating a second wallet never clobbers the
/// first wallet's per-wallet device share.
void main() {
  group('planWalletSwitch (pure routing decision)', () {
    test('already-active + unlocked target short-circuits', () {
      // hasShare / password are irrelevant once the target is active+unlocked.
      expect(
        LibwalletBackend.planWalletSwitch(
          targetIsActiveAndUnlocked: true,
          hasLocalDeviceShare: false,
          passwordProvided: false,
        ),
        SwitchPlan.alreadyActive,
      );
    });

    test('no local device share -> needsRecovery (even with a password)', () {
      expect(
        LibwalletBackend.planWalletSwitch(
          targetIsActiveAndUnlocked: false,
          hasLocalDeviceShare: false,
          passwordProvided: true,
        ),
        SwitchPlan.needsRecovery,
      );
    });

    test('share present but no password -> needsPassword', () {
      expect(
        LibwalletBackend.planWalletSwitch(
          targetIsActiveAndUnlocked: false,
          hasLocalDeviceShare: true,
          passwordProvided: false,
        ),
        SwitchPlan.needsPassword,
      );
    });

    test('share present and password provided -> proceed', () {
      expect(
        LibwalletBackend.planWalletSwitch(
          targetIsActiveAndUnlocked: false,
          hasLocalDeviceShare: true,
          passwordProvided: true,
        ),
        SwitchPlan.proceed,
      );
    });

    test('recovery gate wins over the password gate', () {
      expect(
        LibwalletBackend.planWalletSwitch(
          targetIsActiveAndUnlocked: false,
          hasLocalDeviceShare: false,
          passwordProvided: false,
        ),
        SwitchPlan.needsRecovery,
      );
    });
  });

  group('create no-clobber (per-wallet device shares coexist)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    });

    test('writing a second wallet leaves the first wallet readable', () async {
      // Mirrors what create/_persist does: writeDeviceShare(walletId: ...).
      final ks = SecureKeystore();
      await ks.writeDeviceShare(
        walletId: 'wlt-A',
        value: 'shareA',
        password: 'pwA',
      );
      await ks.writeDeviceShare(
        walletId: 'wlt-B',
        value: 'shareB',
        password: 'pwB',
      );
      expect(
        await ks.readDeviceShare(walletId: 'wlt-A', password: 'pwA'),
        'shareA',
        reason: 'creating wallet B must not overwrite wallet A',
      );
      expect(
        await ks.readDeviceShare(walletId: 'wlt-B', password: 'pwB'),
        'shareB',
      );
    });
  });
}
