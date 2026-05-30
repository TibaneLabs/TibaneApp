import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/screens/wallet/wallet_details_screen.dart';

/// Phase 4 unit tests for the detail screen's action decision:
/// `WalletDetailsScreen.walletDetailActions(isActive, hasShareHere)` decides
/// whether "Use this wallet" is shown (non-active only) and whether the
/// "needs 2FA on this device" hint appears (non-active + no local share).
/// The full screen render needs the real theme/WalletService/client, so it's
/// verified on-device.
void main() {
  group('WalletDetailsScreen.walletDetailActions', () {
    test('active wallet -> no Use button, no hint', () {
      final a = WalletDetailsScreen.walletDetailActions(
        isActive: true,
        hasShareHere: true,
      );
      expect(a.showUse, isFalse);
      expect(a.showNeeds2fa, isFalse);
    });

    test('non-active with local share -> Use button, no hint', () {
      final a = WalletDetailsScreen.walletDetailActions(
        isActive: false,
        hasShareHere: true,
      );
      expect(a.showUse, isTrue);
      expect(a.showNeeds2fa, isFalse);
    });

    test('non-active without local share -> Use button + 2FA hint', () {
      final a = WalletDetailsScreen.walletDetailActions(
        isActive: false,
        hasShareHere: false,
      );
      expect(a.showUse, isTrue);
      expect(a.showNeeds2fa, isTrue);
    });

    test('active without share (edge) -> still no Use button / no hint', () {
      final a = WalletDetailsScreen.walletDetailActions(
        isActive: true,
        hasShareHere: false,
      );
      expect(a.showUse, isFalse);
      expect(a.showNeeds2fa, isFalse);
    });
  });
}
