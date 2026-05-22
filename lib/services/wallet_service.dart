import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:libwallet/libwallet.dart' show NetworkType, Transaction;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/solana_constants.dart';
import 'relay_service.dart';
import 'rpc_service.dart';
import 'wallet/libwallet_backend.dart';
import 'wallet/mwa_wallet_backend.dart';
import 'wallet/wallet_backend.dart';
import 'wallet/walletconnect_bridge.dart';

/// Backend selector persisted across launches.
enum WalletKind { mwa, inapp }

WalletKind _parseKind(String? s) => switch (s) {
      'inapp' => WalletKind.inapp,
      _ => WalletKind.mwa,
    };

String _kindToString(WalletKind k) => k == WalletKind.inapp ? 'inapp' : 'mwa';

/// Façade that routes every wallet call to the active [WalletBackend]. Screens
/// and auth flows continue to use this class; only the backends change.
class WalletService extends ChangeNotifier {
  WalletService() {
    _mwa.addListener(_onBackendChanged);
    _libwallet.addListener(_onBackendChanged);
    _libwallet.balanceTick.addListener(_onBalanceTick);
  }

  final MwaWalletBackend _mwa = MwaWalletBackend();
  final LibwalletBackend _libwallet = LibwalletBackend();
  final _auth = AuthService();

  WalletKind _kind = WalletKind.mwa;
  BigInt _solBalance = BigInt.zero;
  BigInt _chiefPussyBalance = BigInt.zero;

  // --- public API kept compatible with previous WalletService ---

  WalletBackend get active => _kind == WalletKind.inapp ? _libwallet : _mwa;

  /// The current backend kind. UI reads this to decide what buttons to show.
  WalletKind get kind => _kind;

  /// Direct access to specific backends for setup flows (create wallet, unlock).
  MwaWalletBackend get mwa => _mwa;
  LibwalletBackend get libwallet => _libwallet;

  WalletConnectBridge? _wc;

  /// Lazily build a [WalletConnectBridge] tied to the libwallet client. The
  /// bridge isn't started here — call [WalletConnectBridge.start] from the
  /// WC screen once the user opts in.
  Future<WalletConnectBridge> walletConnect(
    GlobalKey<NavigatorState> navKey,
  ) async {
    final existing = _wc;
    if (existing != null) return existing;
    final client = await _libwallet.ensureClient();
    final bridge = WalletConnectBridge(
      client: client,
      backend: _libwallet,
      rootNavigatorKey: navKey,
    );
    _wc = bridge;
    return bridge;
  }

  /// The WC bridge if it has been initialized in this session, else null.
  WalletConnectBridge? get wcOrNull => _wc;

  String? get publicKey => active.publicKey;
  String? get walletName => active.walletName;
  BigInt get solBalance => _solBalance;
  BigInt get chiefPussyBalance => _chiefPussyBalance;
  bool get isConnected => active.isConnected;
  bool get isAuthenticated => _auth.isAuthenticated;
  bool get isConnecting => active.isConnecting;
  String? get error => active.error;

  String get shortAddress {
    final addr = publicKey;
    if (addr == null) return '';
    if (addr.length <= 8) return addr;
    return '${addr.substring(0, 4)}...${addr.substring(addr.length - 4)}';
  }

  Future<void> tryRestore() async {
    final prefs = await SharedPreferences.getInstance();
    _kind = _parseKind(prefs.getString('wallet_backend'));
    await _mwa.tryRestore();
    await _libwallet.tryRestore();
    if (isConnected) {
      refreshBalances();
      if (!_auth.isAuthenticated) {
        _authenticateWithServer();
      }
    }
    notifyListeners();
  }

  /// Connect via the Seed Vault / external MWA flow.
  Future<void> connectMwa() async {
    await _setKind(WalletKind.mwa);
    final ok = await _mwa.connect();
    if (ok) {
      refreshBalances();
      _authenticateWithServer();
    }
  }

  /// Switch to the in-app libwallet backend. Assumes the wallet has already
  /// been created or unlocked via the in-app setup flow.
  Future<void> useLibwallet() async {
    await _setKind(WalletKind.inapp);
    if (isConnected) {
      refreshBalances();
      _authenticateWithServer();
    }
  }

  Future<void> disconnect() async {
    await active.disconnect();
    _solBalance = BigInt.zero;
    _chiefPussyBalance = BigInt.zero;
    _solFiatUsd = 0;
    _chiefPussyFiatUsd = 0;
    await _auth.logout();
    notifyListeners();
  }

  void updateBalances({BigInt? sol, BigInt? chiefPussy}) {
    if (sol != null) _solBalance = sol;
    if (chiefPussy != null) _chiefPussyBalance = chiefPussy;
    notifyListeners();
  }

  /// Convenience for code that wants per-asset fiat values without
  /// fetching the asset list a second time. Updated alongside
  /// [_solBalance] / [_chiefPussyBalance] on every successful refresh.
  double _solFiatUsd = 0;
  double _chiefPussyFiatUsd = 0;
  double get solFiatUsd => _solFiatUsd;
  double get chiefPussyFiatUsd => _chiefPussyFiatUsd;

  /// Bumped by the swap screen after every successful swap. Listened to by
  /// the wallet dashboard so it reloads assets + tx history without waiting
  /// for the txHistoryUpdates stream to fire.
  final ValueNotifier<int> swapCommittedTick = ValueNotifier(0);

  /// In-memory per-address transaction cache. libwallet's local table is
  /// shared across every wallet ever created on this device and the
  /// shared-table window can push an underused wallet's history off the
  /// first page; keeping the most recent filtered result per address
  /// means switching back to that wallet renders the cached rows
  /// immediately instead of re-paginating the shared table.
  final Map<String, List<Transaction>> _txCacheByAddress = {};

  /// Cached transactions for [address], or `null` if nothing has been
  /// loaded yet for this wallet in the current process. The dashboard
  /// reads this on mount for an instant render before its background
  /// fetch lands.
  List<Transaction>? cachedTxsFor(String? address) {
    if (address == null || address.isEmpty) return null;
    return _txCacheByAddress[address];
  }

  /// Replace the cached transactions for [address] with the result of
  /// a fresh fetch.
  void cacheTxsFor(String address, List<Transaction> txs) {
    if (address.isEmpty) return;
    _txCacheByAddress[address] = List.unmodifiable(txs);
  }

  /// Call from any flow that knows a tx just committed (swap, send, …) to
  /// kick downstream views into a refresh.
  void notifyTxCommitted() {
    swapCommittedTick.value++;
    refreshBalances();
  }

  /// Scan the user's on-chain SPL token accounts (legacy + Token-2022) and
  /// register any mints that aren't yet in libwallet's Token table. Needed
  /// because libwallet's Asset:list only surfaces tracked tokens — a user
  /// whose wallet predates Helius DAS auto-discovery (or whose discovery
  /// gate flipped without success) has rows on-chain that never appear in
  /// the dashboard. After registration the dashboard reloads via
  /// [swapCommittedTick] so the new rows render without a manual refresh.
  Future<void> discoverHoldings() async {
    final addr = publicKey;
    if (addr == null) {
      debugPrint('[holdings] skip: no publicKey');
      return;
    }
    if (_kind != WalletKind.inapp || !_libwallet.hasWallet) {
      debugPrint('[holdings] skip: kind=$_kind hasWallet=${_libwallet.hasWallet}');
      return;
    }
    // The dashboard fires this from initState before NetworkChip /
    // ensureSolanaDefault populate the cached network, so `currentNetwork`
    // is null on first launch and the discovery would silently skip.
    // Resolve it now so the gate uses the actual libwallet state.
    final net =
        _libwallet.currentNetwork ?? await _libwallet.refreshCurrentNetwork();
    if (net == null || net.type != NetworkType.solana || net.testNet) {
      debugPrint(
        '[holdings] skip: network=${net?.id} type=${net?.type} '
        'testNet=${net?.testNet}',
      );
      return;
    }

    debugPrint('[holdings] scanning on-chain SPL accounts for $addr');
    final rpc = RpcService();
    try {
      final results = await Future.wait([
        rpc.getTokenAccountsByOwner(addr),
        rpc.getTokenAccountsByOwner(addr, token2022: true),
      ]);
      debugPrint(
        '[holdings] RPC returned ${results[0].length} SPL + '
        '${results[1].length} Token-2022 accounts',
      );
      final onChain =
          <String, ({int decimals, String type})>{};
      for (final acc in [...results[0], ...results[1]]) {
        if (acc.amount <= BigInt.zero) continue;
        onChain[acc.mint] = (
          decimals: acc.decimals,
          type: acc.isToken2022 ? 'spl-token-2022' : 'spl-token',
        );
      }
      debugPrint(
        '[holdings] non-zero on-chain mints: ${onChain.length} '
        '${onChain.keys.toList()}',
      );
      if (onChain.isEmpty) return;

      final client = await _libwallet.ensureClient();
      final tracked = await client.tokens.list();
      final trackedAddrs = tracked.map((t) => t.address).toSet();
      debugPrint(
        '[holdings] libwallet currently tracks ${trackedAddrs.length} tokens',
      );

      var anyAdded = false;
      for (final entry in onChain.entries) {
        if (trackedAddrs.contains(entry.key)) {
          debugPrint('[holdings]   already tracked: ${entry.key}');
          continue;
        }
        debugPrint(
          '[holdings]   missing: ${entry.key} '
          '(decimals=${entry.value.decimals} type=${entry.value.type}) — '
          'registering…',
        );
        final added = await _libwallet.ensureTokenTracked(
          mint: entry.key,
          decimals: entry.value.decimals,
          type: entry.value.type,
        );
        debugPrint('[holdings]   ensureTokenTracked(${entry.key}) → $added');
        if (added) anyAdded = true;
      }
      debugPrint('[holdings] done. anyAdded=$anyAdded');
      if (anyAdded) swapCommittedTick.value++;
    } catch (e) {
      debugPrint('[holdings] discoverHoldings failed: $e');
    } finally {
      rpc.dispose();
    }
  }

  Future<void> refreshBalances() async {
    final addr = publicKey;
    if (addr == null) return;
    // Prefer libwallet's whitelist when an in-app wallet is loaded — it
    // already filters to curated + user-tracked tokens and carries fiat
    // amounts via the `convert: 'USD'` param. Falls back to a direct
    // RPC scan for MWA mode where libwallet has no account context.
    if (_kind == WalletKind.inapp && _libwallet.hasWallet) {
      try {
        var assets = await _libwallet.getAssets();
        // libwallet 0.4.28 auto-discovers Solana fungibles on first
        // Asset:list, but users who set up before 0.4.28 had the
        // discovery gate flipped without success. If ChiefPussy isn't
        // in the list yet, register it explicitly and re-fetch.
        final hasCp = assets.any((a) =>
            a.symbol == 'ChiefPussy' || a.key.contains(chiefPussyMint));
        if (!hasCp) {
          if (await _libwallet.ensureChiefPussyTracked()) {
            assets = await _libwallet.getAssets();
          }
        }
        BigInt sol = BigInt.zero;
        BigInt cp = BigInt.zero;
        double solFiat = 0;
        double cpFiat = 0;
        for (final a in assets) {
          if (a.isNative && a.symbol.toUpperCase() == 'SOL') {
            sol = a.amount.value;
            solFiat = a.fiatAmount?.toDouble() ?? 0;
          } else if (a.symbol == 'ChiefPussy' ||
              a.key.contains(chiefPussyMint)) {
            cp = a.amount.value;
            cpFiat = a.fiatAmount?.toDouble() ?? 0;
          }
        }
        _solBalance = sol;
        _chiefPussyBalance = cp;
        _solFiatUsd = solFiat;
        _chiefPussyFiatUsd = cpFiat;
        notifyListeners();
        return;
      } catch (e) {
        debugPrint('libwallet refreshBalances failed, falling back to RPC: $e');
      }
    }
    final rpc = RpcService();
    try {
      _solBalance = await rpc.getBalance(addr);
      final splAccounts = await rpc.getTokenAccountsByOwner(addr);
      var cp = BigInt.zero;
      for (final account in splAccounts) {
        if (account.mint == chiefPussyMint) {
          cp += account.amount;
        }
      }
      _chiefPussyBalance = cp;
      _solFiatUsd = 0;
      _chiefPussyFiatUsd = 0;
      notifyListeners();
    } catch (e) {
      debugPrint('refreshBalances error: $e');
    } finally {
      rpc.dispose();
    }
  }

  Future<String?> signAndSendTransaction(Uint8List tx) async {
    final results = await active.signAndSendTransactions([tx]);
    return results.isEmpty ? null : results.first;
  }

  Future<List<String?>> signAndSendTransactions(List<Uint8List> txs) =>
      active.signAndSendTransactions(txs);

  Future<Uint8List?> signTransaction(Uint8List tx) async {
    final results = await active.signTransactions([tx]);
    return results.isEmpty ? null : results.first;
  }

  Future<List<Uint8List?>> signTransactions(List<Uint8List> txs) =>
      active.signTransactions(txs);

  Future<Uint8List?> signMessage(Uint8List message) =>
      active.signMessage(message);

  void clearError() {
    active.clearError();
  }

  // --- internals ---

  Future<void> _setKind(WalletKind kind) async {
    if (_kind == kind) return;
    _kind = kind;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wallet_backend', _kindToString(kind));
    notifyListeners();
  }

  void _onBackendChanged() {
    notifyListeners();
  }

  void _onBalanceTick() {
    if (_kind == WalletKind.inapp && isConnected) {
      refreshBalances();
    }
  }

  // tryRestore / connectMwa / useLibwallet all fire-and-forget this and the
  // bare `_auth.isAuthenticated` guard only blocks calls that arrive *after*
  // a prior login has finished. Two concurrent callers both saw false,
  // both did a full getTicket → sign → solLogin. Coalesce onto one future.
  Future<void>? _authFuture;

  Future<void> _authenticateWithServer() {
    if (_auth.isAuthenticated) return Future.value();
    return _authFuture ??= _runAuthenticate();
  }

  Future<void> _runAuthenticate() async {
    try {
      final addr = publicKey;
      if (addr == null) return;
      final (:message, :ticket) = await _auth.getTicket(addr);
      final signature = await signMessage(Uint8List.fromList(utf8.encode(message)));
      if (signature == null) return;
      await _auth.login(ticket, signature);
      notifyListeners();
    } catch (e) {
      debugPrint('authenticateWithServer failed: $e');
    } finally {
      _authFuture = null;
    }
  }

  @override
  void dispose() {
    _mwa.removeListener(_onBackendChanged);
    _libwallet.removeListener(_onBackendChanged);
    _libwallet.balanceTick.removeListener(_onBalanceTick);
    super.dispose();
  }
}
