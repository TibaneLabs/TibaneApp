import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:libwallet/libwallet.dart' show Asset, NetworkType, Transaction;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/solana_constants.dart';
import 'relay_service.dart';
import 'rpc_service.dart';
import 'tx_confirmation.dart';
import 'wallet/accounts_service.dart';
import 'wallet/libwallet_backend.dart';
import 'wallet/mwa_wallet_backend.dart';
import 'wallet/unified_account.dart';
import 'wallet/wallet_backend.dart';
import 'wallet/walletconnect_bridge.dart';

/// Backend selector persisted across launches.
enum WalletKind { mwa, inapp }

WalletKind _parseKind(String? s) => switch (s) {
  'inapp' => WalletKind.inapp,
  _ => WalletKind.mwa,
};

String _kindToString(WalletKind k) => k == WalletKind.inapp ? 'inapp' : 'mwa';

/// Resolve the effective backend kind. If MWA is selected but not connected
/// while an in-app wallet is available, fall back to in-app — otherwise the
/// app gets stuck showing "Connect" (active = the disconnected MWA backend)
/// even though a usable in-app wallet is loaded. Happens when a cancelled
/// "Connect external" left `wallet_backend=mwa` persisted, or an MWA session
/// didn't restore. Otherwise [kind] is unchanged.
@visibleForTesting
WalletKind reconcileWalletKind({
  required WalletKind kind,
  required bool mwaConnected,
  required bool inAppHasWallet,
}) {
  if (kind == WalletKind.mwa && !mwaConnected && inAppHasWallet) {
    return WalletKind.inapp;
  }
  return kind;
}

/// Façade that routes every wallet call to the active [WalletBackend]. Screens
/// and auth flows continue to use this class; only the backends change.
class WalletService extends ChangeNotifier {
  WalletService() {
    _accountsService = AccountsService(_libwallet, _mwa);
    // Re-emit so existing `context.watch<WalletService>()` consumers rebuild
    // when the account list / current account changes.
    _accountsService.addListener(notifyListeners);
    _mwa.addListener(_onBackendChanged);
    _libwallet.addListener(_onBackendChanged);
    _libwallet.balanceTick.addListener(_onBalanceTick);
  }

  final MwaWalletBackend _mwa = MwaWalletBackend();
  final LibwalletBackend _libwallet = LibwalletBackend();

  /// Single source of truth for the account list + current account (Phase
  /// "accounts cubit"). WalletService delegates its account API to this.
  late final AccountsService _accountsService;
  AccountsService get accountsService => _accountsService;

  final _auth = AuthService();

  WalletKind _kind = WalletKind.mwa;

  // Fallback SOL / ChiefPussy balances for MWA mode, where libwallet has no
  // account context and [_assets] isn't populated (filled by the RPC scan in
  // _refreshBalancesOnce). For in-app wallets the balances are derived from
  // [_assets] (the single source) — see the [solBalance]/[chiefPussyBalance]
  // getters; these fields are NOT read there.
  BigInt _solBalanceFallback = BigInt.zero;
  BigInt _chiefPussyFallback = BigInt.zero;

  // The current account's asset list (Ellipx AssetCubit equivalent, §4.4).
  // WalletService is the SINGLE listener to libwallet's balance stream and the
  // source of truth — screens read [assets] (and watch this notifier) instead
  // of each subscribing to libwallet themselves. Loaded by refreshBalances on
  // balanceTick / swap / account change.
  List<Asset> _assets = const [];
  List<Asset> get assets => _assets;

  // True once the first balance/asset snapshot has loaded since launch, or
  // there's genuinely no wallet. The startup splash (D16) gates on this;
  // WalletService owns it because it's the one listening to libwallet.
  bool _dataReady = false;
  bool get dataReady => _dataReady;

  // True once tryRestore() has finished. Lets the startup splash (D16) tell
  // "no wallet yet, restore pending" apart from "restored, genuinely no
  // wallet" — the latter can reveal the app immediately.
  bool _restored = false;
  bool get hasRestored => _restored;

  // --- public API kept compatible with previous WalletService ---

  WalletBackend get active => _kind == WalletKind.inapp ? _libwallet : _mwa;

  /// The current backend kind. UI reads this to decide what buttons to show.
  WalletKind get kind => _kind;

  /// The unified account list (in-app accounts across all wallets + the
  /// connected MWA account). Owned by [accountsService]; rebuilt by
  /// [refreshAccounts]. Empty until the first refresh.
  List<UnifiedAccount> get accounts => _accountsService.accounts;

  /// The account that signs right now, as a [UnifiedAccount]. Reflects the
  /// active backend; null when no account is resolved yet.
  UnifiedAccount? get currentAccount => _accountsService.current;

  /// Whether to show Solana-only features (Staking, Incinerator) for the
  /// current account. False only when the current account is a known
  /// non-Solana (e.g. an EVM in-app account); see [solanaOnlyFeaturesEnabled].
  bool get solanaFeaturesEnabled =>
      solanaOnlyFeaturesEnabled(_accountsService.current);

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
      accounts: _accountsService,
      rootNavigatorKey: navKey,
    );
    _wc = bridge;
    return bridge;
  }

  /// The WC bridge if it has been initialized in this session, else null.
  WalletConnectBridge? get wcOrNull => _wc;

  String? get publicKey => active.publicKey;

  String? get walletName => active.walletName;

  /// Native SOL balance for the current account. Single source of truth is the
  /// libwallet asset list ([assets]); falls back to the cached RPC value for
  /// MWA, where [assets] isn't populated.
  BigInt get solBalance =>
      _nativeSolAsset()?.amount.value ?? _solBalanceFallback;

  /// ChiefPussy is a Solana-only SPL token — report a balance only while a
  /// Solana network is active (or MWA, which is Solana). Off-Solana it's
  /// hidden so a stale value never lingers on an EVM/BTC account.
  BigInt get chiefPussyBalance => _solanaNetworkActive
      ? (_chiefPussyAsset()?.amount.value ?? _chiefPussyFallback)
      : BigInt.zero;

  /// Whether the active context is Solana — the in-app current network is
  /// Solana, or MWA (Seed Vault is Solana-only).
  bool get _solanaNetworkActive =>
      _kind == WalletKind.mwa ||
      _libwallet.currentNetwork?.type == NetworkType.solana;

  Asset? _nativeSolAsset() {
    for (final a in _assets) {
      if (a.isNative && a.symbol.toUpperCase() == 'SOL') return a;
    }
    return null;
  }

  Asset? _chiefPussyAsset() {
    for (final a in _assets) {
      if (a.symbol == 'ChiefPussy' || a.key.contains(chiefPussyMint)) return a;
    }
    return null;
  }

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
    // libwallet's built-in default is Ethereum mainnet, so a fresh
    // install (no wallet, no explicit pick) shows the wrong network
    // chip on the dashboard. Normalize to Solana mainnet on every
    // cold start — ensureSolanaDefault no-ops once the user has
    // explicitly picked a network via NetworksScreen.
    unawaited(_libwallet.ensureSolanaDefault());
    // A persisted `mwa` selection with no restored MWA session would leave the
    // app stuck on "Connect" despite an in-app wallet being present — fall back.
    _reconcileKind();
    if (isConnected) {
      refreshBalances();
    } else {
      // No wallet to load — nothing for the startup splash to wait on.
      _dataReady = true;
    }
    unawaited(refreshAccounts());
    _restored = true;
    notifyListeners();
  }

  /// Connect via the Seed Vault / external MWA flow. Returns true on success;
  /// false when the user cancelled or no MWA wallet app is installed (the
  /// reason is on [mwa].error so the caller can surface it).
  Future<bool> connectMwa() async {
    // Connect FIRST, then switch the active backend — so a cancelled/declined
    // authorize leaves the current (e.g. in-app) wallet active instead of
    // stranding the app on a half-connected MWA backend. NO eager atonline
    // login here: under the lockless model server-login is lazy
    // (ensureServerAuthenticated). For MWA an eager signMessage would re-launch
    // the wallet right after authorize — the "stuck on the other wallet" +
    // background-kill loop. ClawdWallet pulls auth on demand.
    final ok = await _mwa.connect();
    if (!ok) return false;
    await _setKind(WalletKind.mwa);
    refreshBalances();
    unawaited(refreshAccounts());
    return true;
  }

  /// Switch to the in-app libwallet backend. Assumes the wallet has already
  /// been created or unlocked via the in-app setup flow.
  Future<void> useLibwallet() async {
    await _setKind(WalletKind.inapp);
    if (isConnected) {
      refreshBalances();
    }
    unawaited(refreshAccounts());
  }

  Future<void> disconnect() async {
    await active.disconnect();
    resetSessionState();
    _authedAddress = null;
    await _auth.logout();
    unawaited(refreshAccounts());
    notifyListeners();
  }

  /// Rebuild [accounts] from libwallet (`accounts.list()` across all wallets) +
  /// the connected MWA account, and reconcile [currentAccount] with the active
  /// backend. Additive in Phase 4b-1: the active backend is still driven by
  /// [_kind]; this only mirrors it as a [UnifiedAccount]. Best-effort.
  Future<void> refreshAccounts() =>
      _accountsService.refresh(preferMwa: _kind == WalletKind.mwa);

  /// Create a new account on [walletId] (D10 add-account), refresh the unified
  /// list, and switch to it. [type] must be curve-compatible (constrained in
  /// the UI via `allowedAccountTypesForCurve`). Returns false on failure.
  Future<bool> addAccount({
    required String walletId,
    required String name,
    required String type,
  }) async {
    final acct = await _accountsService.createAccount(
      walletId: walletId,
      name: name,
      type: type,
    );
    if (acct == null) return false;
    await refreshAccounts();
    for (final a in _accountsService.accounts) {
      if (a.accountId == acct.id) {
        await setCurrentAccount(a);
        break;
      }
    }
    return true;
  }

  /// Make [acct] the current account: route signing to its backend, then have
  /// [accountsService] switch libwallet to its wallet + account (in-app) and
  /// persist the choice. Reconciles backend kind + refreshes balances around
  /// the switch. Returns false if an in-app switch failed.
  Future<bool> setCurrentAccount(
    UnifiedAccount acct, {
    String? networkId,
  }) async {
    if (acct.isMwa) await _setKind(WalletKind.mwa);
    final ok = await _accountsService.setCurrent(acct, networkId: networkId);
    if (!ok) return false;
    if (acct.isInApp) await _setKind(WalletKind.inapp);
    if (isConnected) refreshBalances();
    notifyListeners();
    return true;
  }

  /// Report the host app's foreground/background state to libwallet so its
  /// background pollers (balances, tx-history) pause off-screen and
  /// resume-poll immediately on foreground (fixing the up-to-60s stale window
  /// after a cold resume). Best-effort — the libwallet client may not be ready.
  /// See BALANCE_REFRESH_SPEC.md (Gap 4).
  Future<void> reportLifecycle(String status) async {
    try {
      final client = await _libwallet.ensureClient();
      await client.lifecycle.update(status);
    } catch (_) {
      // best-effort; client not initialized / no wallet
    }
  }

  void updateBalances({BigInt? sol, BigInt? chiefPussy}) {
    if (sol != null) _solBalanceFallback = sol;
    if (chiefPussy != null) _chiefPussyFallback = chiefPussy;
    notifyListeners();
  }

  /// Zero the session-scoped balance/fiat snapshot. Called when the active
  /// wallet or account changes so stale figures don't linger before the
  /// fresh fetch lands. The per-address tx cache isolates automatically
  /// (it's keyed by address), so it's left intact.
  @visibleForTesting
  void resetSessionState() {
    _solBalanceFallback = BigInt.zero;
    _chiefPussyFallback = BigInt.zero;
    _solFiatFallback = 0;
    _chiefPussyFiatFallback = 0;
  }

  // Fallback per-asset fiat values for MWA mode (see the balance fallbacks
  // above). For in-app wallets these are derived from [assets].
  double _solFiatFallback = 0;
  double _chiefPussyFiatFallback = 0;

  double get solFiatUsd =>
      _nativeSolAsset()?.fiatAmount?.toDouble() ?? _solFiatFallback;

  double get chiefPussyFiatUsd => _solanaNetworkActive
      ? (_chiefPussyAsset()?.fiatAmount?.toDouble() ?? _chiefPussyFiatFallback)
      : 0;

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
  ///
  /// A send/swap returns at **broadcast** time — on Solana the balance/token
  /// state doesn't reflect the tx for ~2-5s after that, so an immediate
  /// refresh can read pre-confirmation (stale) data. We refresh now (cheap,
  /// catches anything already settled) AND schedule a couple of delayed
  /// refreshes so the confirmed state lands quickly without waiting on
  /// libwallet's ~60s background poller. These are scheduled at the service
  /// level so they survive the originating screen being popped (e.g. the send
  /// screen closes on success). See BALANCE_REFRESH_SPEC.md (Gap 1).
  void notifyTxCommitted() {
    _refreshAfterTx();
    // Service-level (guarded by isConnected, not mounted) so the delayed
    // re-polls survive the originating screen being popped. Screens with their
    // own data use the TxConfirmationRefresh mixin with the same delays.
    for (final d in kTxConfirmationDelays) {
      Future.delayed(d, () {
        if (isConnected) _refreshAfterTx();
      });
    }
  }

  void _refreshAfterTx() {
    swapCommittedTick.value++;
    refreshBalances();
  }

  /// A tracked token was added/removed (a local libwallet token-table change,
  /// NOT an on-chain tx). Reload the balance-derived views once so a newly
  /// added token appears on the dashboard immediately — no confirmation
  /// re-polls, since there's nothing to wait for. See BALANCE_REFRESH_SPEC.md
  /// (Gap 3).
  void notifyTokenListChanged() => _refreshAfterTx();

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
      debugPrint(
        '[holdings] skip: kind=$_kind hasWallet=${_libwallet.hasWallet}',
      );
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
      final onChain = <String, ({int decimals, String type})>{};
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

  /// Guards [refreshBalances] so overlapping/rapid calls share one in-flight
  /// scan instead of each kicking a fresh on-chain fetch.
  Future<void>? _refreshInFlight;

  Future<void> refreshBalances() {
    // libwallet's Asset:list (getAssets) makes libwallet snapshot balances and
    // emit a balanceChanges event, which re-enters _onBalanceTick ->
    // refreshBalances. Without coalescing, a single trigger amplifies into a
    // storm of redundant scans (observed: ~5 scans from one dashboard open).
    // Sharing the in-flight future collapses the echo storm into one scan;
    // libwallet stops emitting once the value stabilizes, ending the cascade.
    return _refreshInFlight ??= _refreshBalancesOnce().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<void> _refreshBalancesOnce() async {
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
        final hasCp = assets.any(
          (a) => a.symbol == 'ChiefPussy' || a.key.contains(chiefPussyMint),
        );
        if (!hasCp) {
          if (await _libwallet.ensureChiefPussyTracked()) {
            assets = await _libwallet.getAssets();
          }
        }
        // [assets] is the single source — SOL / ChiefPussy balances + fiat are
        // derived from it via the getters; no separate extraction needed.
        _assets = assets;
        _dataReady = true;
        notifyListeners();
        return;
      } catch (e) {
        debugPrint('libwallet refreshBalances failed, falling back to RPC: $e');
      }
    }
    final rpc = RpcService();
    try {
      // MWA / fallback path: libwallet has no account context, so [_assets]
      // stays empty and the getters read these cached values instead.
      _solBalanceFallback = await rpc.getBalance(addr);
      final splAccounts = await rpc.getTokenAccountsByOwner(addr);
      var cp = BigInt.zero;
      for (final account in splAccounts) {
        if (account.mint == chiefPussyMint) {
          cp += account.amount;
        }
      }
      _chiefPussyFallback = cp;
      _solFiatFallback = 0;
      _chiefPussyFiatFallback = 0;
      _dataReady = true;
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

  /// Fix a stale active-backend selection in place: see [reconcileWalletKind].
  /// Persists the corrected kind. Does NOT notify (callers do).
  void _reconcileKind() {
    final resolved = reconcileWalletKind(
      kind: _kind,
      mwaConnected: _mwa.isConnected,
      inAppHasWallet: _libwallet.publicKey != null,
    );
    if (resolved == _kind) return;
    _kind = resolved;
    unawaited(
      SharedPreferences.getInstance().then(
        (p) => p.setString('wallet_backend', _kindToString(resolved)),
      ),
    );
  }

  // Last active address we reacted to — drives reset + re-auth on change.
  String? _lastAddress;

  void _onBackendChanged() {
    // Recover from a stale `mwa` selection (e.g. MWA disconnected, or an
    // in-app switch happened via a path that didn't update _kind) so the
    // app-bar button + active backend track the usable wallet.
    _reconcileKind();
    final addr = active.publicKey;
    if (addr != _lastAddress) {
      _lastAddress = addr;
      // The active wallet/account changed: drop stale balances so the
      // previous wallet's figures don't linger before the fresh fetch. The
      // per-address tx cache isolates on its own. The server session is
      // re-minted for the new address by the next _authenticateWithServer
      // call (now address-aware) — e.g. useLibwallet right after a switch.
      //
      // NOTE: a live WalletConnect bridge still exposes the previous account;
      // emitting accountsChanged to dApps on switch is tracked separately.
      resetSessionState();
    }
    notifyListeners();
  }

  void _onBalanceTick() {
    if (_kind == WalletKind.inapp && isConnected) {
      refreshBalances();
    }
  }

  // Address the current server session was authenticated for. Switching
  // wallets/accounts changes the address, so the session must be re-minted
  // for the new one. Server-login is LAZY under the lockless model — driven by
  // `ensureServerAuthenticated(ctx)` (begin/completeServerLogin) when a
  // server-backed feature (ClawdWallet) is opened — never eagerly on
  // connect/restore/switch (eager MWA login would re-launch the wallet app).
  String? _authedAddress;

  /// Whether the atonline server session is authenticated for the CURRENT
  /// account address (a stale session for another address doesn't count).
  bool get isAuthenticatedForCurrent =>
      _auth.isAuthenticated && _authedAddress == publicKey;

  /// Begin a server (atonline) login: returns the ticket + the message to sign,
  /// or null when already authenticated for this address or there's no address.
  /// Drops a stale session for a different address first.
  Future<({String message, String ticket})?> beginServerLogin() async {
    if (isAuthenticatedForCurrent) return null;
    final addr = publicKey;
    if (addr == null) return null;
    if (_auth.isAuthenticated && _authedAddress != addr) {
      await _auth.logout();
    }
    return _auth.getTicket(addr);
  }

  /// Complete a server login with the [signature] over the ticket message.
  Future<void> completeServerLogin(String ticket, Uint8List signature) async {
    await _auth.login(ticket, signature);
    _authedAddress = publicKey;
    notifyListeners();
  }

  @override
  void dispose() {
    _accountsService.removeListener(notifyListeners);
    _accountsService.dispose();
    _mwa.removeListener(_onBackendChanged);
    _libwallet.removeListener(_onBackendChanged);
    _libwallet.balanceTick.removeListener(_onBalanceTick);
    super.dispose();
  }
}
