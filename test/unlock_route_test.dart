import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/screens/wallet/inapp_unlock_screen.dart';

/// Phase 3 unit tests for the unlock routing. `InAppUnlockScreen.unlockRoute`
/// is the pure decision that drives whether the screen offers biometric,
/// asks for a password, or routes to 2FA recovery — and whether biometric is
/// even valid for the requested wallet (the cache is single-slot, so only the
/// active wallet). The screen's full render/flow needs the real theme +
/// WalletService + libwallet client, so it's verified on-device.
void main() {
  group('InAppUnlockScreen.unlockRoute', () {
    test('no local share -> recovery (regardless of biometric/active)', () {
      expect(
        InAppUnlockScreen.unlockRoute(
          hasLocalShare: false,
          biometricEnabled: true,
          targetIsActive: true,
        ),
        UnlockRoute.recovery,
      );
    });

    test('share + biometric + active target -> biometric', () {
      expect(
        InAppUnlockScreen.unlockRoute(
          hasLocalShare: true,
          biometricEnabled: true,
          targetIsActive: true,
        ),
        UnlockRoute.biometric,
      );
    });

    test('share + biometric but NON-active target -> password', () {
      // The biometric cache is single-slot — it can only unlock the active
      // wallet, so a different target must go through the password.
      expect(
        InAppUnlockScreen.unlockRoute(
          hasLocalShare: true,
          biometricEnabled: true,
          targetIsActive: false,
        ),
        UnlockRoute.password,
      );
    });

    test('share + no biometric -> password', () {
      expect(
        InAppUnlockScreen.unlockRoute(
          hasLocalShare: true,
          biometricEnabled: false,
          targetIsActive: true,
        ),
        UnlockRoute.password,
      );
    });
  });
}
