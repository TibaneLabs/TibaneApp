import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

/// Phase 5 unit tests. `LibwalletBackend.accountSwitchRoute` decides what
/// tapping an account does: no-op (already current), same-wallet `setCurrent`,
/// or switch-the-parent-wallet-first then `setCurrent`. The UI
/// (`AccountsManagementScreen`) drives the cross-wallet case through
/// `ensureUnlocked(walletId:)` — verified on-device.
void main() {
  group('accountSwitchRoute', () {
    test('tapping the already-current account is a no-op', () {
      expect(
        LibwalletBackend.accountSwitchRoute(
          targetAccountId: 'acc-1',
          currentAccountId: 'acc-1',
          targetWalletId: 'wlt-A',
          activeWalletId: 'wlt-A',
        ),
        AccountSwitchRoute.alreadyCurrent,
      );
    });

    test('different account on the active wallet -> sameWallet', () {
      expect(
        LibwalletBackend.accountSwitchRoute(
          targetAccountId: 'acc-2',
          currentAccountId: 'acc-1',
          targetWalletId: 'wlt-A',
          activeWalletId: 'wlt-A',
        ),
        AccountSwitchRoute.sameWallet,
      );
    });

    test('account on a different wallet -> crossWallet', () {
      expect(
        LibwalletBackend.accountSwitchRoute(
          targetAccountId: 'acc-9',
          currentAccountId: 'acc-1',
          targetWalletId: 'wlt-B',
          activeWalletId: 'wlt-A',
        ),
        AccountSwitchRoute.crossWallet,
      );
    });

    test('no active wallet yet -> crossWallet', () {
      expect(
        LibwalletBackend.accountSwitchRoute(
          targetAccountId: 'acc-9',
          currentAccountId: null,
          targetWalletId: 'wlt-B',
          activeWalletId: null,
        ),
        AccountSwitchRoute.crossWallet,
      );
    });

    test('already-current takes precedence even across wallets', () {
      // Defensive: if somehow the current account id matches, it's a no-op
      // regardless of the wallet ids.
      expect(
        LibwalletBackend.accountSwitchRoute(
          targetAccountId: 'acc-1',
          currentAccountId: 'acc-1',
          targetWalletId: 'wlt-B',
          activeWalletId: 'wlt-A',
        ),
        AccountSwitchRoute.alreadyCurrent,
      );
    });
  });
}
