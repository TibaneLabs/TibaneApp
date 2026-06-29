import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet_service.dart';

/// Unit tests for the active-backend reconciliation. A persisted `mwa`
/// selection with no live MWA session must not strand the app on "Connect"
/// when a usable in-app wallet is present — `reconcileWalletKind` falls back to
/// in-app. The full WalletService wiring (restore + backend-change listeners)
/// is device-verified.
void main() {
  group('reconcileWalletKind', () {
    test('mwa selected but disconnected + in-app wallet present → in-app', () {
      expect(
        reconcileWalletKind(
          kind: WalletKind.mwa,
          mwaConnected: false,
          inAppHasWallet: true,
        ),
        WalletKind.inapp,
      );
    });

    test('mwa connected → keep mwa (never steal from a live session)', () {
      expect(
        reconcileWalletKind(
          kind: WalletKind.mwa,
          mwaConnected: true,
          inAppHasWallet: true,
        ),
        WalletKind.mwa,
      );
    });

    test('mwa disconnected but no in-app wallet → keep mwa (nothing to fall back to)', () {
      expect(
        reconcileWalletKind(
          kind: WalletKind.mwa,
          mwaConnected: false,
          inAppHasWallet: false,
        ),
        WalletKind.mwa,
      );
    });

    test('in-app selected → unchanged regardless of MWA state', () {
      expect(
        reconcileWalletKind(
          kind: WalletKind.inapp,
          mwaConnected: false,
          inAppHasWallet: true,
        ),
        WalletKind.inapp,
      );
      expect(
        reconcileWalletKind(
          kind: WalletKind.inapp,
          mwaConnected: true,
          inAppHasWallet: false,
        ),
        WalletKind.inapp,
      );
    });
  });
}
