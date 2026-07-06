import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:libwallet/libwallet.dart'
    show Asset, NetworkType, Transaction, TxHistoryUpdatedEvent;

import '../constants/solana_constants.dart';
import '../utils/coalescer.dart';
import 'jupiter_service.dart';
import 'wallet_service.dart';

/// Centralized, reactive store for the wallet's token holdings + transaction
/// history and their refresh. Screens consume it via `provider` instead of each
/// spinning up its own [JupiterService] and reload logic — so there's exactly
/// one place that decides how/when this data refreshes. See
/// BALANCES_STORE_MIGRATION.md.
///
/// Phase 1 scope: owns the Solana SPL holdings (Jupiter-discovered) + the tx
/// list. Native / tracked-token balances still live on [WalletService]
/// (`assets`), which this store reads through; later phases fold those in too.
class BalancesStore extends ChangeNotifier {
  BalancesStore(this._wallet, {JupiterService? jupiter})
    : _jupiter = jupiter ?? JupiterService();

  final WalletService _wallet;
  final JupiterService _jupiter;

  List<TokenHolding> _holdings = const [];
  List<Transaction> _transactions = const [];
  bool _loadingTxs = true;

  /// Solana SPL holdings (Jupiter-discovered; excludes wSOL). Empty off-Solana.
  List<TokenHolding> get holdings => _holdings;

  /// Recent transactions for the active address.
  List<Transaction> get transactions => _transactions;

  /// True until the first tx fetch for the active address completes.
  bool get loadingTxs => _loadingTxs;

  /// Native + tracked-token balances (with fiat). Still *owned* by
  /// WalletService (it's wired into the startup gate); surfaced here so screens
  /// read all balance data from one place — this store is the single
  /// consumption facade. See BALANCES_STORE_MIGRATION.md §6.
  List<Asset> get assets => _wallet.assets;

  /// Native balance (lamports on Solana), forwarded from WalletService.
  BigInt get solBalance => _wallet.solBalance;

  StreamSubscription<TxHistoryUpdatedEvent>? _txHistorySub;
  bool _kickedHistoryBackfill = false;
  String? _lastAddress;
  bool _disposed = false;

  // Coalesce overlapping reloads (the balanceTick poller can echo several times
  // per cycle) into one run + a single catch-up.
  late final Coalescer _reloader = Coalescer(_reloadOnce);

  /// Wire up listeners and do the first load. Call once, right after creation.
  void init() {
    _lastAddress = _wallet.publicKey;
    // Prime the tx list from the per-address cache for an instant first paint.
    final cached = _wallet.cachedTxsFor(_lastAddress);
    if (cached != null) {
      _transactions = cached;
      _loadingTxs = false;
    }
    // Reload on: a committed tx (swap/send), the balance poller / tx-broadcast
    // nudge, and libwallet's tx-history backfill stream. Address/account
    // switches reset first (see [_onWalletChanged]).
    _wallet.addListener(_onWalletChanged);
    _wallet.swapCommittedTick.addListener(_onReloadTrigger);
    _wallet.libwallet.balanceTick.addListener(_onReloadTrigger);
    unawaited(_subscribeHistory());
    unawaited(_reload());
    unawaited(_wallet.discoverHoldings());
  }

  void _onReloadTrigger() => unawaited(_reload());

  void _onWalletChanged() {
    final addr = _wallet.publicKey;
    if (addr == _lastAddress) return; // only react to address/account switches
    _lastAddress = addr;
    _holdings = const [];
    final cached = _wallet.cachedTxsFor(addr);
    _transactions = cached ?? const [];
    _loadingTxs = cached == null;
    _kickedHistoryBackfill = false;
    notifyListeners();
    unawaited(_reload());
    unawaited(_wallet.discoverHoldings());
  }

  Future<void> _subscribeHistory() async {
    try {
      final client = await _wallet.libwallet.ensureClient();
      _txHistorySub = client.txHistoryUpdates.listen((_) {
        unawaited(_reload());
      });
    } catch (e) {
      debugPrint('[balances] txHistoryUpdates subscribe failed: $e');
    }
  }

  /// Single post-tx entry point for screens: refresh the balance-derived views
  /// now + on the confirmation schedule, and (Solana) confirm on-chain then
  /// reload until the balance settles. Delegates to WalletService's refresh
  /// machinery; this store's own holdings/tx reload rides the resulting
  /// swapCommittedTick bump. Call this from screens instead of
  /// `wallet.notifyTxCommitted()` + `wallet.confirmAndRefresh()`.
  void onTxCommitted(String? signature) {
    _wallet.notifyTxCommitted();
    unawaited(_wallet.confirmAndRefresh(signature));
  }

  /// Pull-to-refresh: force fresh balances (WalletService), on-chain SPL
  /// discovery, a tx-history backfill sweep, then reload holdings + tx.
  Future<void> refresh() async {
    unawaited(_wallet.refreshBalances());
    unawaited(_wallet.discoverHoldings());
    unawaited(_wallet.libwallet.kickHistoryBackfill());
    await _reload();
  }

  Future<void> _reload() => _reloader.run();

  Future<void> _reloadOnce() async {
    final lw = _wallet.libwallet;
    final addr = _wallet.publicKey;
    // Jupiter is a Solana RPC — calling it with an EVM address fails, so skip
    // it off-Solana; EVM token balances come from WalletService.assets.
    final isSolana =
        (lw.currentNetwork?.type ?? NetworkType.solana) == NetworkType.solana;
    try {
      final results = await Future.wait([
        lw.getTransactions(limit: 50, forAddress: addr),
        if (addr != null && isSolana)
          _jupiter.fetchHoldings(addr, excludeMint: wsolMint)
        else
          Future.value(const <TokenHolding>[]),
      ]);
      if (_disposed) return;
      final txs = results[0] as List<Transaction>;
      final holdings = results[1] as List<TokenHolding>;
      if (addr != null) _wallet.cacheTxsFor(addr, txs);
      _transactions = txs;
      _holdings = holdings;
      _loadingTxs = false;
      notifyListeners();
      // Kick libwallet's tx-history backfill once per address so incoming
      // transfers that were never indexed still surface. Idempotent / cheap.
      if (!_kickedHistoryBackfill) {
        _kickedHistoryBackfill = true;
        unawaited(lw.kickHistoryBackfill());
      }
    } catch (e) {
      debugPrint('[balances] reload failed: $e');
      if (_disposed) return;
      _loadingTxs = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _reloader.cancel();
    _txHistorySub?.cancel();
    _wallet.removeListener(_onWalletChanged);
    _wallet.swapCommittedTick.removeListener(_onReloadTrigger);
    _wallet.libwallet.balanceTick.removeListener(_onReloadTrigger);
    _jupiter.dispose();
    super.dispose();
  }
}
