import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet_service.dart';

/// Phase 9 unit tests. On a wallet/account switch the session-scoped state
/// must not show stale figures: `resetSessionState` zeros the balance/fiat
/// snapshot, and the transaction cache is keyed by address so different
/// active addresses never read each other's history. (The address-change
/// reaction + re-auth wiring needs the live backend, so it's verified
/// on-device.)
void main() {
  test('resetSessionState zeros the balance and fiat snapshot', () {
    final ws = WalletService();
    addTearDown(ws.dispose);

    ws.updateBalances(sol: BigInt.from(5), chiefPussy: BigInt.from(7));
    expect(ws.solBalance, BigInt.from(5));
    expect(ws.chiefPussyBalance, BigInt.from(7));

    ws.resetSessionState();

    expect(ws.solBalance, BigInt.zero);
    expect(ws.chiefPussyBalance, BigInt.zero);
    expect(ws.solFiatUsd, 0);
    expect(ws.chiefPussyFiatUsd, 0);
  });

  test('tx cache is keyed by address — switching address isolates history', () {
    final ws = WalletService();
    addTearDown(ws.dispose);

    ws.cacheTxsFor('addrA', const []);

    // addrA has a (empty) cached entry; a different active address sees none.
    expect(ws.cachedTxsFor('addrA'), isNotNull);
    expect(ws.cachedTxsFor('addrB'), isNull);
  });
}
