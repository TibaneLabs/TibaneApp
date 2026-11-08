import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:libwallet/libwallet.dart'
    show Asset, NetworkType, Transaction, SigningKey;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/solana_constants.dart';
import 'catcard/catcard_wallet_backend.dart';
import 'coinbase_spot_price_service.dart';
import 'activity_history_cache.dart';
import 'eth_usd_price_service.dart';
import 'ethereum_rpc_service.dart';
import 'relay_service.dart';
import 'rpc_service.dart';
import 'tx_confirmation.dart';
import 'wallet/accounts_service.dart';
import 'wallet/asset_network.dart';
import 'wallet/libwallet_backend.dart';
import 'wallet/logical_wallet.dart';
import 'wallet/mwa_wallet_backend.dart';
import 'wallet/unified_account.dart';
import 'wallet/wallet_backend.dart';
import 'wallet/walletconnect_bridge.dart';

/// Backend selector persisted across launches.
enum WalletKind { mwa, inapp, catcard }

WalletKind _parseKind(String? s) => switch (s) {
  'inapp' => WalletKind.inapp,
  'catcard' => WalletKind.catcard,
  _ => WalletKind.mwa,
};

String _kindToString(WalletKind k) => switch (k) {
  WalletKind.inapp => 'inapp',
  WalletKind.catcard => 'catcard',
  WalletKind.mwa => 'mwa',
};

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
  bool catCardConnected = false,
}) {
  if (kind == WalletKind.mwa && !mwaConnected && inAppHasWallet) {
    return WalletKind.inapp;
  }
  if (kind == WalletKind.catcard && !catCardConnected && inAppHasWallet) {
    return WalletKind.inapp;
  }
  return kind;
}

/// Whether a just-broadcast tx should be RPC-confirmed before a post-tx
/// refresh: only a Solana tx that carries a real signature. Non-Solana
/// confirmation is provider-specific (e.g. OKX order status) and must NOT be
/// polled via the Solana RPC, which would only ever time out. Pure, for tests.
@visibleForTesting
bool shouldRpcConfirm({required String? signature, required bool isSolana}) =>
    isSolana && signature != null && signature.isNotEmpty;

/// After a tx confirms on-chain, the *derived* balance views still lag a few
/// seconds — the dashboard's SPL rows come from Jupiter and the native balance
/// from libwallet `getAssets`. Reload up to this many times, spaced
/// [kPostConfirmRefreshInterval] apart, stopping as soon as the native balance
/// moves (a send always moves SOL via the fee), so we don't loop on a change we
/// can't observe.
const int kPostConfirmRefreshTries = 6;
const Duration kPostConfirmRefreshInterval = Duration(seconds: 2);

/// Façade that routes every wallet call to the active [WalletBackend]. Screens
/// and auth flows continue to use this class; only the backends change.
class WalletService extends ChangeNotifier {
  WalletService({
    EthereumRpcService? ethereumRpc,
    EthUsdPriceService? ethPriceService,
    LibwalletBackend? libwalletBackend,
    MwaWalletBackend? mwaBackend,
    CatCardWalletBackend? catcardBackend,
  }) : _libwallet = libwalletBackend ?? LibwalletBackend(),
       _mwa = mwaBackend ?? MwaWalletBackend(),
       _catcard = catcardBackend ?? CatCardWalletBackend(),
       _ethereumRpc = ethereumRpc ?? EthereumRpcService(),
       _ethPriceService = ethPriceService ?? EthUsdPriceService() {
    _accountsService = AccountsService(_libwallet, _mwa, catcard: _catcard);
    // Re-emit so existing `context.watch<WalletService>()` consumers rebuild
    // when the account list / current account changes.
    _accountsService.addListener(notifyListeners);
    _mwa.addListener(_onBackendChanged);
    _catcard.addListener(_onBackendChanged);
    _libwallet.addListener(_onBackendChanged);
    _libwallet.balanceTick.addListener(_onBalanceTick);
  }

  final MwaWalletBackend _mwa;
  final LibwalletBackend _libwallet;
  final CatCardWalletBackend _catcard;
  final EthereumRpcService _ethereumRpc;
  final EthUsdPriceService _ethPriceService;
  final Map<String, CoinbaseSpotPriceService> _bitcoinPriceServices = {};

  /// Single source of truth for the account list + current account (Phase
  /// "accounts cubit"). WalletService delegates its account API to this.
  late final AccountsService _accountsService;
  AccountsService get accountsService => _accountsService;

  final _auth = AuthService();

  WalletKind _kind = WalletKind.mwa;

  // RPC balances for MWA mode and the dashboard's direct Solana scan.
  // The direct scan can correct a missing or stale native SOL Asset.
  BigInt _solBalanceFallback = BigInt.zero;
  bool _hasSolRpcBalance = false;
  BigInt _chiefPussyFallback = BigInt.zero;

  // The current account's asset list (Atonline AssetCubit equivalent, §4.4).
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

  WalletBackend get active => switch (_kind) {
    WalletKind.inapp => _libwallet,
    WalletKind.catcard => _catcard,
    WalletKind.mwa => _mwa,
  };

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

  /// The CatCard hardware wallet over USB.
  CatCardWalletBackend get catcard => _catcard;

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

  String? _resetError;
  String? get resetError => _resetError;

  String? get publicKey => active.publicKey;

  String? get walletName => active.walletName;

  /// Native SOL balance for the current account. A fresh direct Solana scan
  /// takes priority when available; otherwise use libwallet's asset list.
  BigInt get solBalance => _hasSolRpcBalance && _solanaNetworkActive
      ? _solBalanceFallback
      : (_nativeSolAsset()?.amount.value ?? _solBalanceFallback);

  BigInt? get ethBalanceWei =>
      _ethereumMainnetActive && _ethBalanceContext == _balanceContextKey()
      ? _ethBalanceWei
      : null;

  BigInt? _ethBalanceWei;
  String? _ethBalanceContext;
  double? _ethPriceUsd;
  String? _ethPriceContext;
  double? _bitcoinFamilyPriceUsd;
  String? _bitcoinFamilyPriceContext;

  double? get ethPriceUsd =>
      _ethereumMainnetActive && _ethPriceContext == _balanceContextKey()
      ? _ethPriceUsd
      : null;

  double? get bitcoinFamilyPriceUsd =>
      _bitcoinFamilySymbol != null &&
          _bitcoinFamilyPriceContext == _balanceContextKey()
      ? _bitcoinFamilyPriceUsd
      : null;

  String? get _bitcoinFamilySymbol {
    final network = _libwallet.currentNetwork;
    if (_kind != WalletKind.inapp || network?.type != NetworkType.bitcoin) {
      return null;
    }
    return switch (network?.chainId) {
      'bitcoin' => 'BTC',
      'bitcoin-cash' => 'BCH',
      'dogecoin' => 'DOGE',
      'litecoin' => 'LTC',
      _ => null,
    };
  }

  bool get _ethereumMainnetActive =>
      _kind == WalletKind.inapp &&
      _libwallet.currentNetwork?.type == NetworkType.evm &&
      _libwallet.currentNetwork?.chainId == '1';

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
      _kind == WalletKind.catcard ||
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
    await _catcard.tryRestore();
    await _libwallet.tryRestore();
    // libwallet's built-in default is Ethereum mainnet, so a fresh install can
    // boot into the wrong family before an account is active. Normalize to
    // Solana mainnet on cold start; account switches still move libwallet to a
    // compatible default network for the selected account family.
    await _libwallet.ensureSolanaDefault();
    // A persisted `mwa` selection with no restored MWA session would leave the
    // app stuck on "Connect" despite an in-app wallet being present — fall back.
    _reconcileKind();
    // Account-centric startup: build the unified account list, then derive the
    // active backend from the RESTORED current account (the persisted
    // current_account_id is authoritative — it encodes in-app vs MWA). This
    // makes the app reopen on whatever account you were last on, instead of a
    // stale restored Seed Vault pubkey overriding your in-app wallet.
    await refreshAccounts();
    final cur = _accountsService.current;
    if (cur != null) {
      if (cur.isInApp &&
          (!_libwallet.hasWallet || _libwallet.accountId != cur.accountId)) {
        // Older seed imports saved accounts without persisting an active wallet.
        await setCurrentAccount(cur);
      } else {
        final desired = cur.isMwa
            ? WalletKind.mwa
            : cur.isCatCard
            ? WalletKind.catcard
            : WalletKind.inapp;
        if (desired != _kind) await _setKind(desired);
      }
    }
    if (isConnected) {
      refreshBalances();
    } else {
      // No wallet to load — nothing for the startup splash to wait on.
      _dataReady = true;
    }
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

  /// Connect a CatCard over USB: pair (code compared on both screens) and
  /// have the person share an account on the device. Switches to it on
  /// success; a cancelled or failed pairing leaves the current wallet active
  /// (the reason is on [catcard].error).
  Future<bool> connectCatCard() async {
    final ok = await _catcard.connect();
    if (!ok) return false;
    await _setKind(WalletKind.catcard);
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

  /// Tear down an EXTERNAL (MWA / Seed Vault) session. This is a no-op for an
  /// in-app wallet on purpose: an in-app MPC wallet is lockless and lives on the
  /// device, and `LibwalletBackend.disconnect()` would DELETE it
  /// (`wallets.delete`). Deleting an in-app wallet is an explicit, confirmed
  /// action only (Wallet details → Remove → `removeWallet`), never a
  /// "disconnect". Guards against the historical footgun where the account
  /// switcher's Disconnect erased the active wallet.
  Future<void> disconnect() async {
    if (_kind != WalletKind.mwa && _kind != WalletKind.catcard) return;
    await active.disconnect();
    resetSessionState();
    _authedAddress = null;
    await _auth.logout();
    unawaited(refreshAccounts());
    notifyListeners();
  }

  /// Remove all wallet identities from this device while preserving unrelated
  /// app preferences and any backup files the user exported elsewhere.
  Future<bool> removeAllWalletsFromDevice() async {
    _resetError = null;
    try {
      final client = await _libwallet.ensureClient();

      // A removed account must not remain authorized in a dApp session.
      try {
        final sessions = await client.walletConnect.sessions();
        for (final session in sessions) {
          try {
            await client.walletConnect.disconnect(session.topic);
          } catch (e) {
            debugPrint(
              '[wallet-reset] could not disconnect ${session.topic}: $e',
            );
          }
        }
      } catch (e) {
        debugPrint('[wallet-reset] WalletConnect cleanup failed: $e');
      } finally {
        await _wc?.stop();
        _wc = null;
      }

      final removed = await _libwallet.removeAllWallets();
      if (!removed) {
        _resetError = _libwallet.error;
        return false;
      }

      // External MWA authorization is also an account shown by the app, so a
      // complete reset disconnects it even when an in-app wallet was active.
      await _mwa.disconnect();
      await _accountsService.clearLocalWalletState();
      await ActivityHistoryCache().clear();
      await _auth.logout();
      _authedAddress = null;
      _lastAddress = null;
      _txCacheByAddress.clear();
      resetSessionState();
      _dataReady = true;
      _restored = true;

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('wallet_backend');
      _kind = WalletKind.inapp;
      notifyListeners();
      return true;
    } catch (e) {
      _resetError = e.toString();
      debugPrint('[wallet-reset] failed: $e');
      notifyListeners();
      return false;
    }
  }

  /// Rebuild [accounts] from libwallet (`accounts.list()` across all wallets) +
  /// the connected MWA account, and reconcile [currentAccount] with the active
  /// backend. Additive in Phase 4b-1: the active backend is still driven by
  /// [_kind]; this only mirrors it as a [UnifiedAccount]. Best-effort.
  Future<void> refreshAccounts() => _accountsService.refresh(
    preferMwa: _kind == WalletKind.mwa,
    preferCatCard: _kind == WalletKind.catcard,
  );

  /// Activate the newly created/imported wallet, never an unrelated current one.
  Future<bool> activateWalletGroup(LogicalWallet group) async {
    await refreshAccounts();
    final candidates = accounts
        .where(
          (account) =>
              account.isInApp &&
              account.address.isNotEmpty &&
              group.containsWallet(account.walletId ?? ''),
        )
        .toList();
    final target =
        candidates
            .where((a) => a.isSolana && a.isMainWalletContext)
            .firstOrNull ??
        candidates.where((a) => a.isSolana).firstOrNull ??
        candidates.where((a) => !a.isVirtual).firstOrNull ??
        candidates.firstOrNull;
    return target != null && await setCurrentAccount(target);
  }

  /// Create a new account on [walletId] (D10 add-account), refresh the unified
  /// list, and switch to it. [type] must be curve-compatible (constrained in
  /// the UI via `allowedAccountTypesForCurve`). Returns false on failure.
  Future<bool> addAccount({
    required String walletId,
    required String name,
    required String type,
    String? preferredChain,
    List<SigningKey>? keys,
  }) async {
    final acct = await _accountsService.createAccount(
      walletId: walletId,
      name: name,
      type: type,
      preferredChain: preferredChain,
      keys: keys,
    );
    if (acct == null) return false;
    await refreshAccounts();
    for (final a in _accountsService.accounts) {
      if (a.accountId == acct.id &&
          (preferredChain == null || a.chain == preferredChain)) {
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
    if (acct.isCatCard) await _setKind(WalletKind.catcard);
    final ok = await _accountsService.setCurrent(acct, networkId: networkId);
    if (!ok) return false;
    if (acct.isInApp) {
      await _setKind(WalletKind.inapp);
      // Rebuild the selected account after libwallet has switched network /
      // account so address fields are rendered in the active chain context
      // (especially Bitcoin, whose receive address is network-shaped).
      await refreshAccounts();
    }
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
    if (sol != null) {
      _solBalanceFallback = sol;
      _hasSolRpcBalance = true;
    }
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
    _hasSolRpcBalance = false;
    _ethBalanceWei = null;
    _ethBalanceContext = null;
    _ethPriceUsd = null;
    _ethPriceContext = null;
    _bitcoinFamilyPriceUsd = null;
    _bitcoinFamilyPriceContext = null;
    _chiefPussyFallback = BigInt.zero;
    _solFiatFallback = 0;
    _chiefPussyFiatFallback = 0;
    _assets = const [];
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
    return _txCacheByAddress['$kind:${libwallet.currentNetwork?.id}:$address'];
  }

  /// Replace the cached transactions for [address] with the result of
  /// a fresh fetch.
  void cacheTxsFor(String address, List<Transaction> txs) {
    if (address.isEmpty) return;
    _txCacheByAddress['$kind:${libwallet.currentNetwork?.id}:$address'] =
        List.unmodifiable(recentActivityTransactions(txs));
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
    // Pull the just-committed tx into the Activity list without a manual
    // refresh — parity with pull-to-refresh (Solution C). Self-skips when
    // there's no libwallet account (MWA).
    unawaited(_libwallet.kickHistoryBackfill());
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
    unawaited(_refreshFresh());
  }

  /// Refresh balances after dropping libwallet's short-lived asset cache, so
  /// the read reflects freshly-confirmed on-chain state instead of a memoized
  /// pre-confirmation snapshot (Solution C). This is what pull-to-refresh gets
  /// implicitly; doing it here removes the "manual refresh works, auto doesn't"
  /// asymmetry. The invalidate is skipped for MWA (no libwallet account) — its
  /// direct-RPC path in [refreshBalances] is already uncached.
  Future<void> _refreshFresh() async {
    if (_kind == WalletKind.inapp && _libwallet.hasWallet) {
      try {
        await _libwallet.invalidateAssetCache();
      } catch (e) {
        debugPrint('[tx] invalidateAssetCache failed: $e');
      }
    }
    await refreshBalances();
  }

  /// Confirm a just-broadcast Solana transaction on-chain, then reload until
  /// the balance views reflect it (Solution A). A send returns at *broadcast*;
  /// [notifyTxCommitted]'s fixed re-polls (now/3s/9s) can all fall before a slow
  /// confirmation. Once confirmed, the derived views still lag — the dashboard's
  /// SPL rows come from Jupiter and the native balance from libwallet
  /// `getAssets`, both trailing a confirmation by a few seconds — so we reload,
  /// *bumping [swapCommittedTick] so the dashboard re-pulls its Jupiter holdings
  /// (not just the headline)*, until the native balance actually moves (capped).
  /// Fire it unawaited — it runs at the service level and survives the
  /// originating screen being popped. No-op for non-Solana (confirmation there
  /// is chain- / provider-specific; the re-polls + poller still cover it).
  Future<void> confirmAndRefresh(String? signature) async {
    final net = _libwallet.currentNetwork;
    final isSolana = (net?.type ?? NetworkType.solana) == NetworkType.solana;
    if (!shouldRpcConfirm(signature: signature, isSolana: isSolana)) return;
    final baseline = solBalance; // a send always moves SOL (fee/rent)
    final rpc = RpcService();
    try {
      final landed = await rpc.confirmTransaction(signature!);
      if (!landed) return;
      for (var i = 0; i < kPostConfirmRefreshTries && isConnected; i++) {
        swapCommittedTick.value++; // reload the dashboard's Jupiter SPL rows
        await _refreshFresh(); // fresh headline + tracked-token balances
        if (solBalance != baseline) break; // settled — stop early
        await Future.delayed(kPostConfirmRefreshInterval);
      }
    } catch (e) {
      debugPrint('[tx] confirmAndRefresh failed: $e');
    } finally {
      rpc.dispose();
    }
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
    // The dashboard fires this from initState before ensureSolanaDefault
    // populates the cached network, so `currentNetwork` is null on first launch
    // and the discovery would silently skip.
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
          '(decimals=${entry.value.decimals} type=${entry.value.type}). '
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
  String? _refreshInFlightContext;

  Future<void> refreshBalances() {
    final contextKey = _balanceContextKey();
    final inFlight = _refreshInFlight;
    if (inFlight != null && _refreshInFlightContext == contextKey) {
      return inFlight;
    }
    // libwallet's Asset:list (getAssets) makes libwallet snapshot balances and
    // emit a balanceChanges event, which re-enters _onBalanceTick ->
    // refreshBalances. Without coalescing, a single trigger amplifies into a
    // storm of redundant scans (observed: ~5 scans from one dashboard open).
    // Sharing the in-flight future collapses the echo storm into one scan;
    // libwallet stops emitting once the value stabilizes, ending the cascade.
    final future = _refreshBalancesOnce(contextKey).whenComplete(() {
      if (_refreshInFlightContext == contextKey) {
        _refreshInFlight = null;
        _refreshInFlightContext = null;
      }
    });
    _refreshInFlight = future;
    _refreshInFlightContext = contextKey;
    return future;
  }

  String _balanceContextKey() {
    final net = _libwallet.currentNetwork;
    return [
      _kind.name,
      _libwallet.walletId ?? '',
      _libwallet.accountId ?? '',
      net?.id ?? '',
      publicKey ?? '',
    ].join('|');
  }

  Future<void> _refreshBalancesOnce(String contextKey) async {
    final addr = publicKey;
    if (addr == null) return;
    if (_ethereumMainnetActive) {
      try {
        final wei = await _ethereumRpc.getBalanceWei(addr);
        if (contextKey != _balanceContextKey()) return;
        _ethBalanceWei = wei;
        _ethBalanceContext = contextKey;
        notifyListeners();
      } catch (e) {
        debugPrint('Ethereum native balance refresh failed: $e');
      }
      try {
        final price = await _ethPriceService.getPriceUsd();
        if (contextKey != _balanceContextKey()) return;
        _ethPriceUsd = price;
        _ethPriceContext = contextKey;
        notifyListeners();
      } catch (e) {
        if (contextKey != _balanceContextKey()) return;
        _ethPriceUsd = null;
        _ethPriceContext = null;
        debugPrint('Ethereum USD price refresh failed: $e');
      }
    }
    // Prefer libwallet's whitelist when an in-app wallet is loaded — it
    // already filters to curated + user-tracked tokens and carries fiat
    // amounts via the `convert: 'USD'` param. Falls back to a direct
    // RPC scan for MWA mode where libwallet has no account context.
    if (_kind == WalletKind.inapp && _libwallet.hasWallet) {
      try {
        var assets = await _libwallet.getAssets();
        if (contextKey != _balanceContextKey()) return;
        // libwallet 0.4.28 auto-discovers Solana fungibles on first
        // Asset:list, but users who set up before 0.4.28 had the
        // discovery gate flipped without success. If ChiefPussy isn't
        // in the list yet, register it explicitly and re-fetch.
        final hasCp = assets.any(
          (a) => a.symbol == 'ChiefPussy' || a.key.contains(chiefPussyMint),
        );
        if (_solanaNetworkActive && !hasCp) {
          if (await _libwallet.ensureChiefPussyTracked()) {
            assets = await _libwallet.getAssets();
            if (contextKey != _balanceContextKey()) return;
          }
        }
        // [assets] is the single source — SOL / ChiefPussy balances + fiat are
        // derived from it via the getters; no separate extraction needed.
        _assets = assets;
        _dataReady = true;
        notifyListeners();
        final bitcoinSymbol = _bitcoinFamilySymbol;
        final network = _libwallet.currentNetwork;
        if (bitcoinSymbol != null && network != null) {
          Asset? native;
          for (final asset in assets) {
            if (asset.isNative && assetBelongsToNetwork(asset, network)) {
              native = asset;
              break;
            }
          }
          final hasLibwalletPrice =
              (native?.fiatAmount?.toDouble() ?? 0) > 0 ||
              (native?.fiatQuote?.price ?? 0) > 0;
          if (native != null &&
              native.amount.value > BigInt.zero &&
              !hasLibwalletPrice) {
            try {
              final service = _bitcoinPriceServices.putIfAbsent(
                bitcoinSymbol,
                () => CoinbaseSpotPriceService(symbol: bitcoinSymbol),
              );
              final price = await service.getPriceUsd();
              if (contextKey != _balanceContextKey()) return;
              _bitcoinFamilyPriceUsd = price;
              _bitcoinFamilyPriceContext = contextKey;
              notifyListeners();
            } catch (e) {
              if (contextKey != _balanceContextKey()) return;
              _bitcoinFamilyPriceUsd = null;
              _bitcoinFamilyPriceContext = null;
              debugPrint('$bitcoinSymbol USD price refresh failed: $e');
            }
          }
        }
        return;
      } catch (e) {
        debugPrint('libwallet refreshBalances failed: $e');
      }
    }
    if (!_solanaNetworkActive) {
      if (contextKey != _balanceContextKey()) return;
      _dataReady = true;
      notifyListeners();
      return;
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
      if (contextKey != _balanceContextKey()) return;
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
      catCardConnected: _catcard.isConnected,
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
      if (addr == null) {
        _assets = const [];
        _dataReady = true;
      }
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
    _ethereumRpc.dispose();
    _ethPriceService.dispose();
    for (final service in _bitcoinPriceServices.values) {
      service.dispose();
    }
    _accountsService.removeListener(notifyListeners);
    _accountsService.dispose();
    _mwa.removeListener(_onBackendChanged);
    _libwallet.removeListener(_onBackendChanged);
    _libwallet.balanceTick.removeListener(_onBalanceTick);
    super.dispose();
  }
}
