import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

/// Regression: Settings → "Lock wallet" must only forget the in-memory
/// secrets, NOT delete the wallet. Deletion is a separate, explicit action on
/// the wallet-detail screen. Earlier the in-app Lock routed through
/// `disconnect()` (which calls `wallets.delete` + wipes the device share), so
/// locking made the wallet vanish from the list.
///
/// `lock()` is the primitive the Settings handler now calls for in-app
/// wallets; this asserts it keeps the wallet identity intact (so the wallet
/// stays listed and re-unlockable) while clearing the unlocked state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'libw_wallet_id': 'wlt-123',
      'libw_account_id': 'acct-123',
      'libw_address': 'SoLAddreSS1111111111111111111111111111111111',
      'libw_name': 'My Wallet',
      // Mark the per-wallet keystore migration done so tryRestore's migration
      // step is a no-op in the unit-test (no platform keystore available).
      'libw_schema_v2': true,
      'libw_biometric_authreq_v1': true,
    });
  });

  test('lock() keeps the wallet present (does not delete it)', () async {
    final backend = LibwalletBackend();
    await backend.tryRestore();

    // Restored from prefs: the wallet exists and is "connected" (address
    // known) but locked (no key material in memory).
    expect(backend.hasWallet, isTrue);
    expect(backend.isConnected, isTrue);
    expect(backend.walletId, 'wlt-123');
    expect(backend.isUnlocked, isFalse);

    backend.lock();

    // After lock the wallet identity is untouched — it still appears in the
    // list and can be unlocked again; only the (already-empty) secrets clear.
    expect(backend.hasWallet, isTrue);
    expect(backend.isConnected, isTrue);
    expect(backend.walletId, 'wlt-123');
    expect(backend.walletName, 'My Wallet');
    expect(backend.isUnlocked, isFalse);
  });
}
