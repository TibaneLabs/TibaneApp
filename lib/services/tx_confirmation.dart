import 'package:flutter/widgets.dart';

/// Offsets (after a broadcast) at which to re-pull on-chain-derived state.
///
/// A Solana transaction returns at broadcast time, but the chain doesn't
/// reflect it for ~2-5s, and libwallet's own balance / tx-history poller can
/// lag ~60s. Re-pulling at these offsets catches the confirmed state quickly.
/// See BALANCE_REFRESH_SPEC.md ("Confirmation latency").
const List<Duration> kTxConfirmationDelays = [
  Duration(seconds: 3),
  Duration(seconds: 9),
];

/// Mixin for screens that re-pull their *own* data after a transaction they
/// initiated, surviving the ~2-5s confirmation latency.
///
/// Pairs with [WalletService.notifyTxCommitted] (which refreshes balances + the
/// dashboard token list and runs its own delayed re-polls at the service level
/// so they survive the screen being popped). Use this mixin for screen-local
/// reloads (e.g. a staking screen's stake view, a swap screen's holdings) that
/// stay mounted after the action.
mixin TxConfirmationRefresh<T extends StatefulWidget> on State<T> {
  /// Run [reload] now and again after each [kTxConfirmationDelays] offset,
  /// skipping any fire after this [State] has been disposed.
  void refreshAfterTx(VoidCallback reload) {
    reload();
    for (final d in kTxConfirmationDelays) {
      Future.delayed(d, () {
        if (mounted) reload();
      });
    }
  }
}
