import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:libwallet/libwallet.dart'
    show Asset, NetworkType, Transaction, TxHistoryUpdatedEvent;

import '../constants/solana_constants.dart';
import '../models/transaction_activity.dart';
import '../utils/coalescer.dart';
import 'jupiter_service.dart';
import 'activity_history_cache.dart';
import 'transaction_activity_service.dart';
import 'wallet_service.dart';
import 'wallet/libwallet_backend.dart' show TransactionHistoryPage;

/// Post-tx "settle" polling: after a tx, reload every [kSettleInterval] until a
/// balance moves, up to [kSettleMaxAttempts] (~its product), covering the gap
/// between the fixed confirmation re-polls and the ~60s background poller.
const Duration kSettleInterval = Duration(seconds: 4);
const int kSettleMaxAttempts = 12;

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
  BalancesStore(
    this._wallet, {
    JupiterService? jupiter,
    TransactionActivityService? activityService,
    ActivityHistoryCache? historyCache,
  }) : _jupiter = jupiter ?? JupiterService(),
       _historyCache = historyCache ?? ActivityHistoryCache(),
       _activityService = activityService ?? TransactionActivityService();

  final WalletService _wallet;
  final JupiterService _jupiter;
  final TransactionActivityService _activityService;
  final ActivityHistoryCache _historyCache;
  String? _restoredHistoryScope;
  bool _historyFailed = false;
  bool get historyFailed => _historyFailed;
  final _activity = <String, TransactionActivity>{};
  String get _historyScope =>
      '${_wallet.kind}:${_wallet.publicKey}:${_wallet.libwallet.currentNetwork?.id}';
  String? _lastScope;
  String? _historyBefore;
  bool _historyHasMore = false;
  bool _loadingMoreHistory = false;
  bool get historyHasMore => _historyHasMore;
  bool get loadingMoreHistory => _loadingMoreHistory;

  TransactionActivity? activityFor(Transaction tx) =>
      _activity['$_historyScope:${tx.hash}'];

  Future<TransactionActivity?> loadActivity(Transaction tx) async {
    final owner = _wallet.publicKey;
    final scope = _historyScope;
    final hash = tx.hash;
    if (owner == null ||
        hash == null ||
        hash.isEmpty ||
        !tx.asset.startsWith('solana.')) {
      return null;
    }
    final key = '$scope:$hash';
    final cached = _activity[key];
    if (cached != null) return cached;
    try {
      final result = await _activityService.loadSolana(hash, owner);
      if (_disposed || scope != _historyScope) return null;
      if (result != null) {
        _activity[key] = result;
        notifyListeners();
        unawaited(_persistHistory(scope));
      }
      return result;
    } catch (e) {
      debugPrint('[activity] transaction details unavailable: $e');
      return null;
    }
  }

  Future<void> _enrichActivity(
    List<Transaction> transactions,
    String? owner,
  ) async {
    // Bound history RPC work and keep the existing balance/price refresh fast.
    final recent = transactions.take(activityHistoryLimit).toList();
    final scope = _historyScope;
    for (var offset = 0; offset < recent.length; offset += 4) {
      if (_disposed || owner != _wallet.publicKey || scope != _historyScope) {
        return;
      }
      await Future.wait(recent.skip(offset).take(4).map(loadActivity));
    }
  }

  List<TokenHolding> _holdings = const [];
  TokenHolding? _nativeSolHolding;
  List<Transaction> _transactions = const [];
  bool _loadingTxs = true;

  /// Solana SPL holdings (Jupiter-discovered; native SOL is kept separately).
  /// Empty off-Solana.
  List<TokenHolding> get holdings => _holdings;

  /// Full native SOL position from the same RPC scan as SPL holdings.
  TokenHolding? get nativeSolHolding => _nativeSolHolding;

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
  int _settleGen = 0; // supersedes an in-flight post-tx settle loop

  // Coalesce overlapping reloads (the balanceTick poller can echo several times
  // per cycle) into one run + a single catch-up.
  late final Coalescer _reloader = Coalescer(_reloadOnce);

  /// Wire up listeners and do the first load. Call once, right after creation.
  void init() {
    _lastScope = _historyScope;
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
    if (_lastScope == _historyScope) return;
    _lastScope = _historyScope;
    _historyBefore = null;
    _restoredHistoryScope = null;
    _historyFailed = false;
    _historyHasMore = false;
    _loadingMoreHistory = false;
    _lastAddress = addr;
    _holdings = const [];
    _activity.clear();
    _nativeSolHolding = null;
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
    unawaited(_settleAfterTx());
  }

  /// Keep reloading balances + holdings until they actually change, then stop
  /// (capped). Closes the gap between [notifyTxCommitted]'s fixed re-polls
  /// (~9s) and the ~60s poller: on Solana, confirmation + Jupiter/libwallet
  /// indexing can take longer than the fixed schedule, so without this the
  /// dashboard sits stale until the next 60s poll. Reloads directly (not via
  /// swapCommittedTick), so it works even if that chain lags. A newer tx
  /// supersedes an in-flight loop via [_settleGen].
  Future<void> _settleAfterTx() async {
    final gen = ++_settleGen;
    final baseSol = _wallet.solBalance;
    final baseFp = _holdingsFingerprint();
    for (var i = 0; i < kSettleMaxAttempts && gen == _settleGen; i++) {
      await Future<void>.delayed(kSettleInterval);
      if (_disposed || gen != _settleGen || !_wallet.isConnected) return;
      await _wallet.refreshBalances(); // SOL / tracked-token balances
      await _reload(); // Jupiter holdings + tx
      if (_wallet.solBalance != baseSol || _holdingsFingerprint() != baseFp) {
        return; // settled — balances reflect the tx
      }
    }
  }

  String _holdingsFingerprint() => _fingerprintOf(_holdings);

  String _fingerprintOf(List<TokenHolding> hs) =>
      hs.map((h) => '${h.mint}:${h.balance}').join(',');

  /// Pull-to-refresh: force fresh balances (WalletService), on-chain SPL
  /// discovery, a tx-history backfill sweep, then reload holdings + tx.
  Future<void> refresh() async {
    unawaited(_wallet.refreshBalances());
    unawaited(_wallet.discoverHoldings());
    await refreshHistory();
  }

  /// Sweep before reading the local table, including when no update event fires.
  Future<void> refreshHistory() async {
    if (_disposed) return;
    final scope = _historyScope;
    await _restoreHistory(scope);
    if (_disposed || scope != _historyScope) return;
    _kickedHistoryBackfill = true;
    _historyFailed = false;
    if (_transactions.isEmpty) {
      _loadingTxs = true;
      notifyListeners();
    }
    await _wallet.libwallet.kickHistoryBackfill();
    if (_disposed || scope != _historyScope) return;
    _historyFailed = _wallet.libwallet.historyBackfillFailed;
    await _reload();
  }

  Future<void> _reload() => _reloader.run();

  Future<void> loadMoreHistory() async {
    if (_loadingMoreHistory || !_historyHasMore || _historyBefore == null) {
      return;
    }
    final scope = _historyScope;
    _loadingMoreHistory = true;
    notifyListeners();
    try {
      final page = await _wallet.libwallet.getTransactionPage(
        forAddress: _wallet.publicKey,
        before: _historyBefore,
      );
      if (_disposed || scope != _historyScope) return;
      _transactions = _mergeHistory(_transactions, page.items);
      _historyBefore = page.before;
      _historyHasMore = page.hasMore;
      unawaited(_enrichActivity(page.items, _wallet.publicKey));
    } finally {
      if (!_disposed && scope == _historyScope) {
        _loadingMoreHistory = false;
        notifyListeners();
      }
    }
  }

  List<Transaction> _mergeHistory(
    List<Transaction> first,
    List<Transaction> second,
  ) {
    return recentActivityTransactions([...first, ...second]);
  }

  Future<void> _restoreHistory(String scope) async {
    if (_restoredHistoryScope == scope || _wallet.publicKey == null) return;
    final snapshot = await _historyCache.read(scope);
    if (_disposed || scope != _historyScope) return;
    _transactions = _mergeHistory(_transactions, snapshot.transactions);
    for (final entry in snapshot.activity.entries) {
      _activity.putIfAbsent('$scope:${entry.key}', () => entry.value);
    }
    _restoredHistoryScope = scope;
    if (_transactions.isNotEmpty) _loadingTxs = false;
    notifyListeners();
  }

  Future<void> _persistHistory(String scope) async {
    if (_disposed || scope != _historyScope || _wallet.publicKey == null) {
      return;
    }
    final hashes = _transactions.map(activityTransactionId).toSet();
    _activity.removeWhere(
      (key, _) =>
          key.startsWith('$scope:') &&
          !hashes.any((hash) => key == '$scope:$hash'),
    );
    await _historyCache.write(
      scope,
      ActivityHistorySnapshot(List.of(_transactions), {
        for (final tx in _transactions)
          activityTransactionId(tx):
              ?_activity['$scope:${activityTransactionId(tx)}'],
      }),
    );
  }

  Future<void> _reloadOnce() async {
    final lw = _wallet.libwallet;
    final addr = _wallet.publicKey;
    final scope = _historyScope;
    await _restoreHistory(scope);
    if (_disposed || scope != _historyScope) return;
    // Jupiter is a Solana RPC — calling it with an EVM address fails, so skip
    // it off-Solana; EVM token balances come from WalletService.assets.
    final isSolana =
        _wallet.kind != WalletKind.inapp ||
        (lw.currentNetwork?.type ?? NetworkType.solana) == NetworkType.solana;
    try {
      final results = await Future.wait<Object?>([
        () async {
          try {
            return await lw.getTransactionPage(limit: 50, forAddress: addr);
          } catch (e) {
            debugPrint('[balances] transaction reload failed: $e');
            if (scope == _historyScope) _historyFailed = true;
            return null;
          }
        }(),
        () async {
          if (addr == null || !isSolana) return const <TokenHolding>[];
          try {
            return await _jupiter.fetchHoldings(addr, reserveSolForFees: false);
          } catch (e) {
            debugPrint('[balances] holdings reload failed: $e');
            return null;
          }
        }(),
      ]);
      if (_disposed || scope != _historyScope) return;
      final page = results[0] as TransactionHistoryPage?;
      final txs = page?.items;
      final allHoldings = results[1] as List<TokenHolding>?;
      if (txs != null) {
        if (_historyBefore == null) {
          _historyBefore = page!.before;
          _historyHasMore = page.hasMore;
        }
        _transactions = _mergeHistory(txs, _transactions);
        unawaited(_persistHistory(scope));
        if (addr != null) _wallet.cacheTxsFor(addr, _transactions);
        unawaited(_enrichActivity(_transactions, addr));
      }
      if (allHoldings != null) {
        final nativeSol = isSolana
            ? allHoldings.where((h) => h.mint == wsolMint).firstOrNull
            : null;
        _holdings = allHoldings.where((h) => h.mint != wsolMint).toList();
        _nativeSolHolding = nativeSol;
        if (nativeSol != null) {
          _wallet.updateBalances(sol: nativeSol.balance);
        }
      }
      _loadingTxs = false;
      notifyListeners();
      // Kick libwallet's tx-history backfill once per address so incoming
      // transfers that were never indexed still surface. Idempotent / cheap.
      if (!_kickedHistoryBackfill) {
        _kickedHistoryBackfill = true;
        unawaited(refreshHistory());
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
    _activityService.dispose();
    super.dispose();
  }
}
