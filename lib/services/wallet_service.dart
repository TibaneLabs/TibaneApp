import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:libwallet/libwallet.dart' show NetworkType, Transaction;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/solana_constants.dart';
import 'relay_service.dart';
import 'rpc_service.dart';
import 'tx_confirmation.dart';
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

  // Account-centric model (Atonline-parity Phase 4b). Additive in this phase:
  // the active backend is still driven by [_kind]; [_currentAccount] reflects
  // it as a UnifiedAccount so the upcoming account switcher (4b-2) has data.
  static const _prefsCurrentAccountId = 'current_account_id';
  List<UnifiedAccount> _accounts = const [];
  UnifiedAccount? _currentAccount;

  // --- public API kept compatible with previous WalletService ---

  WalletBackend get active => _kind == WalletKind.inapp ? _libwallet : _mwa;

  /// The current backend kind. UI reads this to decide what buttons to show.
  WalletKind get kind => _kind;

  /// The unified account list (in-app accounts across all wallets + the
  /// connected MWA account). Rebuilt by [refreshAccounts]. Empty until the
  /// first refresh.
  List<UnifiedAccount> get accounts => _accounts;

  /// The account that signs right now, as a [UnifiedAccount]. Reflects the
  /// active backend; null when no account is resolved yet.
  UnifiedAccount? get currentAccount => _currentAccount;

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
    // libwallet's built-in default is Ethereum mainnet, so a fresh
    // install (no wallet, no explicit pick) shows the wrong network
    // chip on the dashboard. Normalize to Solana mainnet on every
    // cold start — ensureSolanaDefault no-ops once the user has
    // explicitly picked a network via NetworksScreen.
    unawaited(_libwallet.ensureSolanaDefault());
    if (isConnected) {
      refreshBalances();
    }
    unawaited(refreshAccounts());
    notifyListeners();
  }

  /// Connect via the Seed Vault / external MWA flow.
  Future<void> connectMwa() async {
    // Connect FIRST, then switch the active backend — so a cancelled/declined
    // authorize leaves the current (e.g. in-app) wallet active instead of
    // stranding the app on a half-connected MWA backend. NO eager atonline
    // login here: under the lockless model server-login is lazy
    // (ensureServerAuthenticated). For MWA an eager signMessage would re-launch
    // the wallet right after authorize — the "stuck on the other wallet" +
    // background-kill loop. ClawdWallet pulls auth on demand.
    final ok = await _mwa.connect();
    if (!ok) return;
    await _setKind(WalletKind.mwa);
    refreshBalances();
    unawaited(refreshAccounts());
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
  Future<void> refreshAccounts() async {
    try {
      final client = await _libwallet.ensureClient();
      final inapp = await client.accounts.list();
      final wallets = {for (final w in await client.wallets.list()) w.id: w};
      final mwaAddr = _mwa.isConnected ? _mwa.publicKey : null;
      _accounts = buildUnifiedAccounts(
        inappAccounts: inapp,
        walletsById: wallets,
        mwaAddress: mwaAddr,
      );
      final prefs = await SharedPreferences.getInstance();
      _currentAccount =
          _matchActiveAccount(_accounts) ??
          resolvePersistedAccount(
            accounts: _accounts,
            savedId: prefs.getString(_prefsCurrentAccountId),
          );
      notifyListeners();
    } catch (e) {
      debugPrint('refreshAccounts failed: $e');
    }
  }

  /// Create a new account on [walletId] (D10 add-account), refresh the unified
  /// list, and switch to it. [type] must be curve-compatible (constrained in
  /// the UI via `allowedAccountTypesForCurve`). Returns false on failure.
  Future<bool> addAccount({
    required String walletId,
    required String name,
    required String type,
  }) async {
    final acct = await _libwallet.createAccount(
      walletId: walletId,
      name: name,
      type: type,
    );
    if (acct == null) return false;
    await refreshAccounts();
    for (final a in _accounts) {
      if (a.accountId == acct.id) {
        await setCurrentAccount(a);
        break;
      }
    }
    return true;
  }

  /// The unified-list entry corresponding to the active backend, so
  /// [currentAccount] stays consistent with [_kind] during Phase 4b-1.
  UnifiedAccount? _matchActiveAccount(List<UnifiedAccount> accounts) {
    if (_kind == WalletKind.mwa) {
      for (final a in accounts) {
        if (a.isMwa) return a;
      }
      return null;
    }
    final aid = _libwallet.accountId;
    for (final a in accounts) {
      if (a.isInApp && a.accountId == aid) return a;
    }
    return null;
  }

  /// Make [acct] the current account: route signing to its backend, switch
  /// libwallet to its wallet + account when in-app (lockless free switch),
  /// persist the choice, and refresh. Returns false if an in-app switch failed.
  /// Wired into the account switcher in Phase 4b-2.
  Future<bool> setCurrentAccount(UnifiedAccount acct) async {
    if (acct.isMwa) {
      await _setKind(WalletKind.mwa);
    } else {
      final targetWallet = acct.walletId;
      if (targetWallet != null && targetWallet != _libwallet.walletId) {
        final r = await _libwallet.switchWallet(targetWallet);
        if (r != SwitchResult.ok) {
          debugPrint('setCurrentAccount: switchWallet failed ($r)');
          return false;
        }
      }
      final targetAccount = acct.accountId;
      if (targetAccount != null && targetAccount != _libwallet.accountId) {
        if (!await _libwallet.switchAccount(targetAccount)) {
          debugPrint('setCurrentAccount: switchAccount failed: ${_libwallet.error}');
          return false;
        }
      }
      await _setKind(WalletKind.inapp);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsCurrentAccountId, acct.id);
    _currentAccount = acct;
    if (isConnected) {
      refreshBalances();
    }
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
    if (sol != null) _solBalance = sol;
    if (chiefPussy != null) _chiefPussyBalance = chiefPussy;
    notifyListeners();
  }

  /// Zero the session-scoped balance/fiat snapshot. Called when the active
  /// wallet or account changes so stale figures don't linger before the
  /// fresh fetch lands. The per-address tx cache isolates automatically
  /// (it's keyed by address), so it's left intact.
  @visibleForTesting
  void resetSessionState() {
    _solBalance = BigInt.zero;
    _chiefPussyBalance = BigInt.zero;
    _solFiatUsd = 0;
    _chiefPussyFiatUsd = 0;
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

  // Last active address we reacted to — drives reset + re-auth on change.
  String? _lastAddress;

  void _onBackendChanged() {
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
    _mwa.removeListener(_onBackendChanged);
    _libwallet.removeListener(_onBackendChanged);
    _libwallet.balanceTick.removeListener(_onBalanceTick);
    super.dispose();
  }
}
