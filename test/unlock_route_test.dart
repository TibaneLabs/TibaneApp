import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/screens/wallet/inapp_unlock_screen.dart';

/// Unit tests for the unlock routing. After Phase 3b removed the legacy
/// biometric-unlock toggle, `InAppUnlockScreen.unlockRoute` is the pure
/// decision between asking for a password and routing to 2FA recovery (based
/// solely on whether the device share is locally available). The screen's full
/// render/flow needs the real theme + WalletService + libwallet client, so it's
/// verified on-device.
void main() {
  group('InAppUnlockScreen.unlockRoute', () {
    test('no local share -> 2FA recovery', () {
      expect(
        InAppUnlockScreen.unlockRoute(hasLocalShare: false),
        UnlockRoute.recovery,
      );
    });

    test('local share present -> password', () {
      expect(
        InAppUnlockScreen.unlockRoute(hasLocalShare: true),
        UnlockRoute.password,
      );
    });
  });
}
