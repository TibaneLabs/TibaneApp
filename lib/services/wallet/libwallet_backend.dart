import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libwallet/libwallet.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/solana_constants.dart';
import '../relay_service.dart' show tibaneApi;
import '../solana_common.dart';
import 'biometric.dart';
import 'creation.dart';
import 'migration.dart';
import 'secure_keystore.dart';
import 'signing.dart';
import 'wallet_backend.dart';

/// Minimal token result shape returned by
/// [LibwalletBackend.searchCuratedTokens] — symbol/name/mint/image/
/// decimals, suitable for rendering directly in a list or wrapping
/// into a [FavoriteToken] / passing to a swap selector callback.
class TokenSearchResult {
  final String mint;
  final String? name;
  final String? symbol;
  final String? imageUrl;
  final int? decimals;

  const TokenSearchResult({
    required this.mint,
    this.name,
    this.symbol,
    this.imageUrl,
    this.decimals,
  });
}

/// Outcome of [LibwalletBackend.switchWallet]. The UI branches on this to
/// prompt for a password, route into 2FA recovery, or surface an error.
enum SwitchResult { ok, needsPassword, wrongPassword, needsRecovery, error }

/// Pure routing decision for a wallet switch — extracted so it can be
/// unit-tested without a libwallet client. See
/// [LibwalletBackend.planWalletSwitch].
enum SwitchPlan { alreadyActive, needsRecovery, needsPassword, proceed }

/// What must happen before the device-transfer SEND side can release a
/// wallet's StoreKey share. See [LibwalletBackend.deviceTransferSendRoute].
enum DeviceTransferSendRoute {
  /// Target isn't the active wallet — switch to it (which also unlocks) first.
  switchFirst,

  /// Target is active but locked — unlock it to load the StoreKey share.
  unlockFirst,

  /// Target is active and unlocked — open the export session now.
  exportDirectly,
}

/// Routing for tapping an account: it may already be current, live on the
/// active wallet (just `setCurrent`), or belong to a different wallet (switch
/// that wallet first). See [LibwalletBackend.accountSwitchRoute].
enum AccountSwitchRoute { alreadyCurrent, sameWallet, crossWallet }

/// In-app MPC wallet backend. 2-of-3 TSS: device share + remote email share + password.
///
/// Signing uses libwallet 0.3.5's direct `Account:sign*` endpoints with the
/// cached StoreKey + Password shares — no pending-request ceremony.
class LibwalletBackend extends ChangeNotifier implements WalletBackend {
  @override
  String get id => 'inapp';

  static const _prefsWalletId = 'libw_wallet_id';
  static const _prefsAccountId = 'libw_account_id';
  static const _prefsAddress = 'libw_address';
  static const _prefsStorePub = 'libw_store_pub';
  static const _prefsStorePriv = 'libw_store_priv';
  static const _prefsStoreKeyId = 'libw_store_kid';
  static const _prefsRemoteKeyId = 'libw_remote_kid';
  static const _prefsPasswordKeyId = 'libw_pass_kid';
  static const _prefsName = 'libw_name';
  static const _prefsNetworkPicked = 'libw_network_picked';
  static const _prefsAtonlineMigrated = 'libw_atonline_migrated_v1';
  // Legacy 'libw_biometric_enabled' pref + its keystore cache were removed in
  // Phase 3b; SecureKeystore.purgeLegacyBiometricPassword clears the orphans.

  final SecureKeystore _keystore = SecureKeystore();

  LibwalletClient? _client;
  bool _infoRegistered = false;
  StreamSubscription<BalancesChangedEvent>? _balanceSub;
  StreamSubscription<LogEvent>? _logSub;

  /// Increments each time libwallet's background poller reports a balance
  /// change. `WalletService` listens and triggers `refreshBalances()`.
  final ValueNotifier<int> balanceTick = ValueNotifier(0);

  String? _publicKey;
  String? _walletName;
  String? _walletId;
  String? _accountId;

  // Key material cached after create / unlock. Cleared on lock().
  String? _storeKeyPriv;
  String? _storeKeyId;
  String? _remoteKeyId;
  String? _passwordKeyId;
  String? _password;

  // Device-transfer receive scratch state. A wallet received from another
  // device lands in libwallet's local store and its StoreKey share is held
  // here until the user enters the wallet password (activateAfterTransfer).
  // Kept SEPARATE from the active-wallet fields above so receiving never
  // clobbers the currently-active wallet (multi-wallet: add, don't replace).
  // Only the bits activate needs are stashed — switchWallet re-derives the
  // rest from client.wallets.get() when the wallet is made active.
  String? _pendingWalletId;
  String? _pendingName;
  String? _pendingPasswordKeyId;
  String? _pendingStoreKeyPriv;

  bool _connecting = false;
  String? _error;

  @override
  String? get publicKey => _publicKey;

  @override
  String? get walletName => _walletName;

  @override
  bool get isConnected => _publicKey != null;

  @override
  bool get isConnecting => _connecting;

  @override
  String? get error => _error;

  /// True when we have key material in memory ready to sign.
  bool get isUnlocked => _password != null && _storeKeyPriv != null;

  /// True when a wallet exists on this device (but may be locked).
  bool get hasWallet => _walletId != null;

  /// True when the current wallet has no StoreKey share — a D5 password-only
  /// committee `[Password, Password, RemoteKey]`. The legacy `_signingKeys()`
  /// path expects a StoreKey, so such wallets can only be signed via the
  /// per-transaction sign sheet — callers must route them there regardless of
  /// `kLocklessSigning`.
  bool get requiresSignSheet => hasWallet && _storeKeyId == null;

  /// True while a device-transfer has been received but not yet activated
  /// (awaiting the wallet password). Unique to the post-import/pre-activate
  /// window — the active-wallet fields are untouched during this time.
  bool get hasPendingTransfer => _pendingWalletId != null;

  /// Display name of the wallet received via device transfer, if any.
  String? get pendingTransferName => _pendingName;

  /// True when the local SecureKeystore (or its password-encrypted
  /// fallback blob) holds the device-share private. False after a
  /// cross-device backup import, or any time the device share has
  /// gone missing — used by the unlock screen to route between the
  /// normal password prompt and the 2FA recovery flow.
  Future<bool> hasLocalDeviceShare([String? walletId]) async {
    final id = walletId ?? _walletId;
    if (id == null) return false;
    return _keystore.hasDeviceShare(id);
  }

  /// Wallet handle on the libwallet backend; null until a wallet exists.
  String? get walletId => _walletId;

  /// IDs of the three TSS key shares (null until the wallet has been
  /// created and persisted). Exposed so the wallet-details screen can
  /// render each share with its protection mechanism.
  String? get storeKeyId => _storeKeyId;

  String? get remoteKeyId => _remoteKeyId;

  String? get passwordKeyId => _passwordKeyId;

  Network? _currentNetwork;
  bool _networkLoading = false;

  /// The libwallet current-network record, fetched lazily on first
  /// [ensureClient] call after a connection.
  Network? get currentNetwork => _currentNetwork;

  /// Refresh [currentNetwork] from libwallet. Notifies listeners on change.
  Future<Network?> refreshCurrentNetwork() async {
    if (_networkLoading) return _currentNetwork;
    _networkLoading = true;
    try {
      final client = await _getClient();
      final net = await client.networks.getCurrent();
      if (_currentNetwork?.id != net.id) {
        _currentNetwork = net;
        notifyListeners();
      } else {
        _currentNetwork = net;
      }
      return net;
    } catch (e) {
      debugPrint('refreshCurrentNetwork failed: $e');
      return _currentNetwork;
    } finally {
      _networkLoading = false;
    }
  }

  /// Set the current network by its libwallet id. Notifies listeners on
  /// success so dependent UI can refresh. Records that the user has made
  /// a deliberate choice so we don't auto-override it later.
  Future<bool> setCurrentNetwork(String networkId) async {
    try {
      final client = await _getClient();
      await client.networks.setCurrent(networkId);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsNetworkPicked, true);
      await refreshCurrentNetwork();
      // Force a balance refresh tick downstream.
      balanceTick.value++;
      return true;
    } catch (e) {
      _error = 'Switch network failed: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// Pick the most reasonable default network for a Tibane install: Solana
  /// mainnet if available, otherwise leave the current selection. Called
  /// once after the first wallet create / restore so a new install lands
  /// on Solana instead of libwallet's default (Ethereum). Skipped after
  /// the user has explicitly picked a network via [setCurrentNetwork].
  Future<void> ensureSolanaDefault() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefsNetworkPicked) == true) {
        // User has chosen explicitly before — never override.
        await refreshCurrentNetwork();
        return;
      }
      final client = await _getClient();
      final current = await client.networks.getCurrent();
      _currentNetwork = current;
      if (current.type == NetworkType.solana && !current.testNet) {
        notifyListeners();
        return;
      }
      final all = await client.networks.list();
      Network? pick;
      for (final n in all) {
        if (n.type == NetworkType.solana && !n.testNet) {
          pick = n;
          break;
        }
      }
      if (pick == null) {
        notifyListeners();
        return;
      }
      await client.networks.setCurrent(pick.id);
      _currentNetwork = pick;
      notifyListeners();
    } catch (e) {
      debugPrint('ensureSolanaDefault failed: $e');
    }
  }

  /// Defensive: make sure libwallet's Token table tracks the given mint on
  /// the active Solana network. Returns true when a row was newly added so
  /// the caller can re-fetch the asset list. No-op when the token is
  /// already tracked or the active network isn't Solana mainnet.
  ///
  /// Pass [name]/[symbol]/[decimals] when the caller already has them
  /// cached (swap output, deep-link payload, etc.). When any are missing,
  /// libwallet's on-chain `tokens.discover` probe fills them in. Used to
  /// surface freshly-acquired tokens in the dashboard immediately rather
  /// than waiting on the next Helius DAS auto-discovery cycle.
  Future<bool> ensureTokenTracked({
    required String mint,
    String? name,
    String? symbol,
    int? decimals,
    String type = 'spl-token',
  }) async {
    try {
      final client = await _getClient();
      final existing = await client.tokens.list();
      if (existing.any((t) => t.address == mint)) {
        debugPrint('[track] $mint: already in tokens table');
        return false;
      }
      final net = _currentNetwork ?? await client.networks.getCurrent();
      _currentNetwork = net;
      if (net.type != NetworkType.solana || net.testNet) {
        debugPrint(
          '[track] $mint: skip, network=${net.id} type=${net.type} '
          'testNet=${net.testNet}',
        );
        return false;
      }
      final chainKey = '${net.type.name}.${net.chainId}';

      var resolvedName = name ?? '';
      var resolvedSymbol = symbol ?? '';
      var resolvedDecimals = decimals ?? -1;
      var resolvedType = type;
      debugPrint(
        '[track] $mint: incoming name="$resolvedName" symbol="$resolvedSymbol" '
        'decimals=$resolvedDecimals type=$resolvedType',
      );
      if (resolvedSymbol.isEmpty || resolvedDecimals < 0) {
        try {
          final d = await client.tokens.discover(
            network: chainKey,
            address: mint,
          );
          debugPrint(
            '[track] $mint: discover → name="${d.name}" symbol="${d.symbol}" '
            'decimals=${d.decimals} type="${d.type}"',
          );
          if (resolvedName.isEmpty) resolvedName = d.name;
          if (resolvedSymbol.isEmpty) resolvedSymbol = d.symbol;
          if (resolvedDecimals < 0) resolvedDecimals = d.decimals;
          if (d.type.isNotEmpty) resolvedType = d.type;
        } catch (e) {
          debugPrint('[track] $mint: discover failed: $e');
        }
      }
      if (resolvedDecimals < 0) {
        debugPrint('[track] $mint: bail, decimals unresolved');
        return false;
      }
      await client.tokens.create(
        name: resolvedName.isNotEmpty
            ? resolvedName
            : (resolvedSymbol.isNotEmpty ? resolvedSymbol : mint),
        symbol: resolvedSymbol.isNotEmpty ? resolvedSymbol : 'UNK',
        address: mint,
        decimals: resolvedDecimals,
        // tokens.create wants the network UUID, not the "<type>.<chainId>"
        // string that tokens.discover accepts — passing chainKey here
        // returns "invalid UUID length" 500s.
        network: net.id,
        type: resolvedType,
      );
      debugPrint(
        '[track] $mint: created on network ${net.id} '
        'symbol="$resolvedSymbol" decimals=$resolvedDecimals '
        'type=$resolvedType',
      );
      return true;
    } catch (e) {
      debugPrint('[track] $mint: ensureTokenTracked failed: $e');
      return false;
    }
  }

  /// Backwards-compatible shim for the hard-coded ChiefPussy path used
  /// during refreshBalances. Same contract as [ensureTokenTracked].
  Future<bool> ensureChiefPussyTracked() => ensureTokenTracked(
    mint: chiefPussyMint,
    name: 'Tibane Thecat',
    symbol: 'ChiefPussy',
    decimals: 6,
  );

  // Coalesces concurrent first-time initializations. Without this, several
  // callers racing through _getClient at startup (refreshBalances,
  // refreshCurrentNetwork, the dApp browser bootstrap, history subscribe, …)
  // each pass the `_client == null` check during the `await` below and each
  // call LibwalletClient.initialize — spawning a *separate* Go engine, each
  // with its own 60 s balance poller that never stops. The orphaned pollers
  // then hammer RPC N× forever. Sharing one in-flight future guarantees a
  // single engine.
  Future<LibwalletClient>? _clientInit;

  Future<LibwalletClient> _getClient() {
    final existing = _client;
    if (existing != null) return Future.value(existing);
    return _clientInit ??= _initClient();
  }

  Future<LibwalletClient> _initClient() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/libwallet');
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final client = LibwalletClient.initialize(dir.path);
      await client.info.ping();
      await _registerWalletInfo(client);
      _balanceSub ??= client.balanceChanges.listen((_) {
        balanceTick.value++;
      });
      // On Flutter+iOS the Go runtime's stderr is dropped, so libwallet's
      // internal logs only surface via this stream. Pipe them to
      // debugPrint so backfill / RPC / poller activity is visible when
      // diagnosing "empty tx list" type issues.
      _logSub ??= client.logs.listen((e) {
        debugPrint('[libwallet:${e.level}] ${e.message}');
      });
      _client = client;
      return client;
    } catch (e) {
      // Let a later call retry a failed initialization instead of caching
      // the failure for the lifetime of the process.
      _clientInit = null;
      rethrow;
    }
  }

  Future<void> _registerWalletInfo(LibwalletClient client) async {
    if (_infoRegistered) return;
    try {
      await client.info.setWalletInfo(
        clientId: tibaneApi.appId,
        name: 'Tibane',
        logLevel: kDebugMode ? 'debug' : '',
      );
      _infoRegistered = true;
    } catch (e) {
      debugPrint('setWalletInfo failed: $e');
    }
  }

  /// Access the underlying libwallet client, initializing it on first use.
  /// Exposed so components like the in-app browser can subscribe to
  /// `pendingRequests` / `jsEvents` and issue Web3 bridge calls.
  Future<LibwalletClient> ensureClient() => _getClient();

  /// String identifier of the current account (stable across launches);
  /// null before a wallet is created.
  String? get accountId => _accountId;

  /// Signing keys ready to submit with `Request:approve` for the active
  /// session. Empty while the wallet is locked.
  List<Map<String, dynamic>> get currentSigningKeys => _signingKeys();

  @override
  Future<void> tryRestore() async {
    final prefs = await SharedPreferences.getInstance();
    _walletId = prefs.getString(_prefsWalletId);
    _accountId = prefs.getString(_prefsAccountId);
    _publicKey = prefs.getString(_prefsAddress);
    _walletName = prefs.getString(_prefsName) ?? 'In-app wallet';
    _storeKeyId = prefs.getString(_prefsStoreKeyId);
    _remoteKeyId = prefs.getString(_prefsRemoteKeyId);
    _passwordKeyId = prefs.getString(_prefsPasswordKeyId);
    // One-shot, idempotent: move any legacy single-slot device share to the
    // active wallet's per-wallet keys before anything reads it.
    await _keystore.migrateToPerWalletV2(_walletId);
    // One-shot: purge the removed legacy biometric password-cache (Phase 3b).
    await _keystore.purgeLegacyBiometricPassword();
    if (hasWallet) notifyListeners();
  }

  /// Start the remote-share verification. [identifier] is either an email
  /// address (verification sent via mail) or an international-format phone
  /// number like `+14045551234` (verification sent via SMS); the backend
  /// disambiguates on whether it contains an `@`.
  ///
  /// Returns a session descriptor whose `length` tells you how many digits
  /// the verification code will have.
  Future<RemoteKeySession> startVerification(String identifier) async {
    final client = await _getClient();
    final isEmail = identifier.contains('@');
    final session = await client.remoteKeys.create(
      number: isEmail ? null : identifier,
      email: isEmail ? identifier : null,
    );
    debugPrint('remoteKey verification started: length=${session.length}');
    return session;
  }

  /// Backwards-compatible alias retained while older call sites migrate.
  @Deprecated(
    'use startVerification(identifier) which also handles phone numbers',
  )
  Future<RemoteKeySession> startEmailVerification(String email) =>
      startVerification(email);

  /// Complete the verification step. Returns the `remoteKey` identifier to
  /// pass to [create].
  Future<String> verifyEmailCode({
    required String session,
    required String code,
  }) async {
    final client = await _getClient();
    final validation = await client.remoteKeys.validate(
      session: session,
      code: code,
    );
    return validation.remoteKey;
  }

  /// Create one or two fresh 2-of-3 wallets using a previously-verified
  /// remote key. Pass `['ed25519']` for Solana, `['secp256k1']` for
  /// EVM/Bitcoin, or both for a multi-curve setup driven by libwallet's
  /// `Wallet:multiCreate` (single keygen ceremony, no second 2FA code).
  ///
  /// The active wallet/account set on this backend is the first curve in
  /// the list — `ed25519` is preferred when present so Solana flows light
  /// up immediately. All created wallets are visible in
  /// `client.wallets.list()` regardless.
  Stream<double> create({
    required String name,
    required String password,
    required String remoteKey,
    List<String> curves = const ['ed25519'],
  }) async* {
    if (curves.isEmpty) {
      throw ArgumentError('curves must not be empty');
    }
    _connecting = true;
    _error = null;
    notifyListeners();

    try {
      final client = await _getClient();

      // Build the committee (Atonline-parity §5.2 / D5). Biometric: a StoreKey
      // enrolled behind biometric BEFORE keygen — a cancelled/failed enrollment
      // aborts creation here, before any wallet exists. D5 (no biometric): two
      // Password shares + RemoteKey (≥3 keys for multiCreate), no StoreKey.
      final mode = creationModeFor(
        hasBiometric: await Biometric.hasBiometric(),
        forceUnsafe: kForceUnsafeCreation,
      );
      StoreKeyPair? storePair;
      final List<KeyDescription> keys;
      if (mode == CreationMode.biometric) {
        storePair = await client.storeKeys.create();
        await Biometric.setSecuredKey(
          storePair.privateKey,
          storePair.publicKey,
        );
        keys = [
          KeyDescription.storeKey(storePair.publicKey),
          KeyDescription.remoteKey(remoteKey),
          KeyDescription.password(password),
        ];
      } else {
        keys = [
          KeyDescription.password(password),
          KeyDescription.password(password),
          KeyDescription.remoteKey(remoteKey),
        ];
      }

      final Map<String, Wallet> createdByCurve;
      if (curves.length > 1) {
        Map<String, Wallet>? both;
        await for (final ev in client.wallets.multiCreate(
          name: name,
          keys: keys,
        )) {
          switch (ev) {
            case Progress(:final fraction):
              yield fraction;
            case Complete(:final value):
              both = value;
          }
        }
        if (both == null) {
          throw StateError('multiCreate finished without a result');
        }
        createdByCurve = both;
      } else {
        Wallet? single;
        await for (final ev in client.wallets.create(
          name: name,
          curve: curves.first,
          keys: keys,
        )) {
          switch (ev) {
            case Progress(:final fraction):
              yield fraction;
            case Complete(:final value):
              single = value;
          }
        }
        if (single == null) {
          throw StateError('Wallet creation finished without a result');
        }
        createdByCurve = {curves.first: single};
      }

      // Derive a default chain account per wallet — Solana for ed25519,
      // Ethereum for secp256k1. The host-tracked "active" pair is the
      // ed25519/solana one if it exists, else the only one.
      Account? activeAccount;
      Wallet? activeWallet;
      for (final entry in createdByCurve.entries) {
        final w = entry.value;
        final type = entry.key == 'ed25519' ? 'solana' : 'ethereum';
        final accountName = entry.key == 'ed25519' ? 'Solana' : 'Ethereum';
        final acct = await client.accounts.create(
          name: accountName,
          wallet: w.id,
          type: type,
          index: 0,
        );
        if (entry.key == 'ed25519' || activeAccount == null) {
          activeWallet = w;
          activeAccount = acct;
        }
      }

      final wallet = activeWallet!;
      final account = activeAccount!;
      final walletKeyIds = _extractKeyIdsByType(wallet);
      _walletId = wallet.id;
      _accountId = account.id;
      _publicKey = account.address;
      _walletName = name;
      _storeKeyPriv = storePair?.privateKey; // null for the D5 committee
      _storeKeyId = walletKeyIds['StoreKey']; // null for the D5 committee
      _remoteKeyId = walletKeyIds['RemoteKey'];
      _passwordKeyId = walletKeyIds['Password'];
      _password = password;

      // Biometric wallets write the StoreKey blob-only (no no-auth copy);
      // D5 wallets have no StoreKey priv, so _persist skips the share write.
      await _persist(
        storeKeyPublic: storePair?.publicKey,
        osKeystoreCopy: false,
      );
      await ensureSolanaDefault();
      notifyListeners();
    } catch (e) {
      _error = 'Wallet creation failed: $e';
      debugPrint(_error);
      rethrow;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------
  // Biometric migration of existing wallets (Atonline-parity Phase 3 / D7).
  // Moves each StoreKey private from the no-auth keystore to biometric_storage,
  // verify-before-delete, KEEPING the password blob (D8). Idempotent.
  // ------------------------------------------------------------------

  /// Whether the eager one-time biometric-migration screen should be shown:
  /// the device can custody behind biometric, the one-shot flag isn't set, and
  /// at least one StoreKey wallet still has a no-auth keystore copy.
  Future<bool> needsBiometricMigration() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyMigrated = prefs.getBool(_prefsAtonlineMigrated) == true;
    final biometric = await Biometric.hasBiometric();
    if (alreadyMigrated || !biometric) return false;
    var hasWalletToMigrate = false;
    try {
      final client = await _getClient();
      for (final w in await client.wallets.list()) {
        final action = migrationActionForWallet(
          hasStoreKey: w.keys.any((k) => k.type == 'StoreKey'),
          hasNoAuthCopy: await _keystore.hasNoAuthKeystoreCopy(w.id),
        );
        if (action == MigrationAction.migrate) {
          hasWalletToMigrate = true;
          break;
        }
      }
    } catch (e) {
      debugPrint('needsBiometricMigration: $e');
      return false;
    }
    return shouldMigrate(
      alreadyMigrated: alreadyMigrated,
      hasWalletToMigrate: hasWalletToMigrate,
      biometricAvailable: biometric,
    );
  }

  /// Migrate every in-app wallet's StoreKey private from the no-auth keystore
  /// to biometric storage — verify-before-delete, keeping the password blob
  /// (D8). Per-wallet idempotent (a migrated wallet has no no-auth copy left).
  /// Sets the one-shot flag only when EVERY wallet is handled without failure;
  /// any failure leaves the old copy in place to retry. Returns true on full
  /// success.
  Future<bool> migrateToBiometricV1() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_prefsAtonlineMigrated) == true) return true;
    if (!await Biometric.hasBiometric()) return false;
    final client = await _getClient();
    var allOk = true;
    for (final w in await client.wallets.list()) {
      final storeKeys = w.keys.where((k) => k.type == 'StoreKey');
      final storeKey = storeKeys.isEmpty ? null : storeKeys.first;
      final action = migrationActionForWallet(
        hasStoreKey: storeKey != null,
        hasNoAuthCopy: await _keystore.hasNoAuthKeystoreCopy(w.id),
      );
      if (action == MigrationAction.skip) continue;
      try {
        // 1. Read the no-auth share (no password needed).
        final priv = await _keystore.readDeviceShare(
          walletId: w.id,
          password: null,
        );
        if (priv == null) {
          allOk = false; // raced away since the probe — retry next launch
          continue;
        }
        // 2. Enroll behind biometric (prompt) + 3. verify-read (prompt).
        await Biometric.setSecuredKey(priv, storeKey!.key);
        final back = await Biometric.askSecuredKey(storeKey.key);
        if (back != priv) {
          allOk = false; // verify failed — keep the no-auth copy
          continue;
        }
        // 4. Verified — drop the no-auth copy, KEEP the blob (D8).
        await _keystore.deleteNoAuthKeystoreCopy(w.id);
      } catch (e) {
        debugPrint('migrateToBiometricV1(${w.id}): $e');
        allOk = false; // biometric cancel / error — retry next launch
      }
    }
    if (allOk) await prefs.setBool(_prefsAtonlineMigrated, true);
    notifyListeners();
    return allOk;
  }

  /// Import a BIP-39 mnemonic and promote it IN PLACE to the canonical
  /// `[StoreKey, RemoteKey, Password]` committee (threshold 1), the same shape
  /// [create] uses. The wallet's master pubkey/address is preserved — only its
  /// key storage changes from the 1-of-1 password share to the full TSS
  /// committee — so the imported wallet itself becomes the 3-key MPC wallet
  /// (no separate "migrated" wallet, no chain picker).
  ///
  /// The device StoreKey's private share is persisted under the wallet id so
  /// [switchWallet] can unlock it later; without that it would read as
  /// `needsRecovery`. If the promote fails, the just-imported 1-of-1 wallet is
  /// deleted so no stray password-only wallet is left behind.
  ///
  /// Works for both ed25519 (Solana) and secp256k1 (EVM/BTC) seeds. (The
  /// libwallet 0.4.65 godoc claims promote is secp256k1-only, but that is
  /// stale — ed25519 promote is tested working against real infra.)
  ///
  /// - [mnemonic] / [passphrase] / [curve]: the seed to import.
  /// - [name]: the new wallet's display name.
  /// - [password]: encrypts the imported share AND becomes the committee's
  ///   Password share.
  /// - [remoteKey]: a verified 2FA remote-key identifier (see
  ///   [startVerification] / [verifyEmailCode]).
  Future<Wallet> importAndPromoteMnemonic({
    required String mnemonic,
    required String passphrase,
    required String curve,
    required String name,
    required String password,
    required String remoteKey,
  }) async {
    final client = await _getClient();
    // 1-of-1 mnemonic-backed wallet, password-encrypted at rest.
    final imported = await client.wallets.importMnemonic(
      mnemonic: mnemonic,
      passphrase: passphrase,
      curve: curve,
      name: name,
      keys: [KeyDescription.password(password)],
    );
    final storePair = await client.storeKeys.create();
    final Wallet promoted;
    try {
      // Reshare in place into the full committee (address preserved).
      promoted = await client.wallets.promote(
        imported.id,
        oldKeys: [KeyDescription.password(password)],
        newKeys: [
          KeyDescription.storeKey(storePair.publicKey),
          KeyDescription.remoteKey(remoteKey),
          KeyDescription.password(password),
        ],
        threshold: 1,
      );
    } catch (_) {
      // Don't leave a stray 1-of-1 password-only wallet behind.
      try {
        await client.wallets.delete(imported.id);
      } catch (e) {
        debugPrint('importAndPromoteMnemonic cleanup failed: $e');
      }
      rethrow;
    }
    // Persist the device share so switchWallet can read it back.
    await _keystore.writeDeviceShare(
      walletId: promoted.id,
      value: storePair.privateKey,
      password: password,
    );
    return promoted;
  }

  /// Unlock an existing wallet by re-deriving the password share and comparing
  /// against the stored public key. Caches secrets in memory for this session.
  Future<bool> unlock(String password) async {
    if (!hasWallet) {
      _error = 'No in-app wallet';
      notifyListeners();
      return false;
    }
    try {
      final client = await _getClient();
      if (_passwordKeyId == null) {
        _error = 'Missing key metadata; please re-create the wallet';
        notifyListeners();
        return false;
      }
      // Deriving the password public key validates the password without signing.
      await client.storeKeys.derivePassword(
        password: password,
        walletKeyId: _passwordKeyId!,
      );
      // Load the device-share private key. Prefer the SecureKeystore copy;
      // fall back to the legacy plaintext SharedPreferences entry written
      // by builds before secure storage landed and migrate it on the spot.
      String? priv;
      try {
        priv = await _keystore.readDeviceShare(
          walletId: _walletId!,
          password: password,
        );
      } on WrongPasswordException {
        _error = 'Unlock failed: wrong password';
        notifyListeners();
        return false;
      }
      if (priv == null) {
        final prefs = await SharedPreferences.getInstance();
        final legacy = prefs.getString(_prefsStorePriv);
        if (legacy != null) {
          priv = legacy;
          _storeKeyPriv = legacy;
          _password = password;
          await _keystore.writeDeviceShare(
            walletId: _walletId!,
            value: legacy,
            password: password,
          );
          await prefs.remove(_prefsStorePriv);
          debugPrint('Migrated device share to SecureKeystore');
        }
      }
      if (priv == null) {
        // No local device share — the unlock UI is responsible for
        // routing the user through the 2FA recovery flow before
        // calling unlock again. We surface the absence as a typed
        // signal so the host can branch cleanly.
        _error =
            'Device share not found on this device. '
            'Recover via 2FA from the unlock screen.';
        notifyListeners();
        return false;
      }
      _storeKeyPriv = priv;
      _password = password;
      // Backfill the password-encrypted fallback blob for users who
      // installed before that backup path was unconditional. Without
      // this, a future restore-from-iCloud-Backup on a new device
      // would leave them with no recoverable device share. Safe to
      // re-run — writeDeviceShare is idempotent.
      unawaited(
        _keystore.writeDeviceShare(
          walletId: _walletId!,
          value: priv,
          password: password,
        ),
      );
      notifyListeners();
      // Best-effort: refresh the cached current network so the chip and
      // any swap-availability checks reflect what libwallet thinks is
      // active. Default to Solana mainnet if libwallet has rolled the
      // current pointer back to Ethereum (its built-in default).
      unawaited(ensureSolanaDefault());
      return true;
    } catch (e) {
      _error = 'Unlock failed: wrong password?';
      debugPrint('Unlock error: $e');
      notifyListeners();
      return false;
    }
  }

  /// Reshare the active wallet replacing the Password share with a new
  /// secret. Verifies [oldPassword] against the on-device pubkey first;
  /// runs libwallet's TSS reshare; on success, refreshes in-memory
  /// `_password`, re-persists the device share under the new password,
  /// and clears any biometric cache (so the user re-stages it under the
  /// new password). Stage 1: ed25519 wallets only.
  Future<bool> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    if (!hasWallet) {
      _error = 'No in-app wallet';
      notifyListeners();
      return false;
    }
    if (newPassword.length < 8) {
      _error = 'New password must be at least 8 characters';
      notifyListeners();
      return false;
    }
    try {
      final client = await _getClient();
      // Validate the old password without signing.
      if (_passwordKeyId == null || _storeKeyId == null) {
        _error = 'Missing key metadata; cannot change password';
        notifyListeners();
        return false;
      }
      await client.storeKeys.derivePassword(
        password: oldPassword,
        walletKeyId: _passwordKeyId!,
      );
      // Compose old + new descriptors. Same shape, just new Password.
      final old = <KeyDescription>[];
      final fresh = <KeyDescription>[];
      // StoreKey
      final prefs = await SharedPreferences.getInstance();
      final storePub = prefs.getString(_prefsStorePub);
      if (storePub != null) {
        old.add(KeyDescription.storeKey(storePub));
        fresh.add(KeyDescription.storeKey(storePub));
      }
      // RemoteKey
      if (_remoteKeyId != null) {
        old.add(KeyDescription.remoteKey(_remoteKeyId!));
        fresh.add(KeyDescription.remoteKey(_remoteKeyId!));
      }
      // Password — old / new
      old.add(KeyDescription.password(oldPassword));
      fresh.add(KeyDescription.password(newPassword));

      await for (final ev in client.wallets.reshare(
        _walletId!,
        oldKeys: old,
        newKeys: fresh,
      )) {
        if (ev is Complete<Wallet>) {
          final w = ev.value;
          _passwordKeyId = _extractKeyIdsByType(w)['Password'];
        }
      }

      // Re-persist the device share under the new password and refresh
      // the biometric cache if it was enabled.
      _password = newPassword;
      if (_storeKeyPriv != null) {
        await _keystore.writeDeviceShare(
          walletId: _walletId!,
          value: _storeKeyPriv!,
          password: newPassword,
        );
      }
      if (_passwordKeyId != null) {
        await prefs.setString(_prefsPasswordKeyId, _passwordKeyId!);
      }
      notifyListeners();
      unawaited(_maybeAutoBackup()); // keep iCloud/Google copy current
      return true;
    } catch (e) {
      _error = 'Change password failed: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// Start a remote-key reshare for the wallet's 2FA share. Returns the
  /// session descriptor so the UI can prompt for the code; complete by
  /// calling [completeRemoteKeyReshare] with the user-typed digits.
  Future<RemoteKeySession?> startRemoteKeyReshare() async {
    if (_walletId == null) {
      _error = 'No in-app wallet';
      notifyListeners();
      return null;
    }
    try {
      final client = await _getClient();
      final wallet = await client.wallets.get(_walletId!);
      // RemoteKey:reshare expects the RemoteKey resource identifier
      // (`crws-…:crwsv-…`), which lives in the WalletKey's `key` field —
      // NOT the wallet-key id (`wkey-…`). The two are distinct: id
      // identifies the share within this wallet; key is the
      // server-side handle for the RemoteKey resource.
      WalletKey? remoteKey;
      for (final k in wallet.keys) {
        if (k.type == 'RemoteKey') {
          remoteKey = k;
          break;
        }
      }
      if (remoteKey == null || remoteKey.key.isEmpty) {
        _error = 'No remote key configured on this wallet';
        notifyListeners();
        return null;
      }
      // As of libwallet 0.4.41 reshare takes no curve — the backend
      // derives it from the remote key record, removing the foot-gun
      // where a host-side defaulted wallet.curve mis-routed the
      // ceremony into the wrong curve/protocol.
      return await client.remoteKeys.reshare(key: remoteKey.key);
    } catch (e) {
      _error = 'Reshare failed to start: $e';
      debugPrint(_error);
      notifyListeners();
      return null;
    }
  }

  /// Validate the verification code to finish a remote-key reshare. Updates
  /// the local `_remoteKeyId` if the backend rotated it.
  Future<bool> completeRemoteKeyReshare({
    required String session,
    required String code,
  }) async {
    try {
      final client = await _getClient();
      final validation = await client.remoteKeys.validate(
        session: session,
        code: code,
      );
      if (validation.remoteKey.isNotEmpty &&
          validation.remoteKey != _remoteKeyId) {
        _remoteKeyId = validation.remoteKey;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsRemoteKeyId, _remoteKeyId!);
      }
      notifyListeners();
      unawaited(_maybeAutoBackup()); // 2FA share changed — refresh backup
      return true;
    } catch (e) {
      _error = 'Reshare validation failed: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// Cross-device recovery: validate the 2FA verification code to
  /// authorize the RemoteKey share, then auto-rotate the device share
  /// so this device has its own StoreKey going forward. Caller has
  /// already collected the password (validated upstream via
  /// [startRemoteKeyReshare] succeeding) and the verification code.
  /// On success, the wallet ends up fully unlocked (`isUnlocked` true)
  /// — no second call to [unlock] needed.
  Future<bool> recoverDeviceShareVia2fa({
    required String sessionToken,
    required String code,
    required String password,
  }) async {
    if (!hasWallet) {
      _error = 'No in-app wallet';
      notifyListeners();
      return false;
    }
    try {
      final client = await _getClient();
      // Validate the SMS/email code. We need the freshly-minted
      // RemoteKey resource id back from validate — the stored
      // `WalletKey.key` is the original keygen session which the
      // server has marked `done`, and using it in the subsequent
      // Wallet:reshare causes `invalid status for wallet sign
      // session: done`. Per libwallet 0.4.37 device_share.md, the
      // validate result's `remoteKey` field replaces it on both
      // old and new committee RemoteKey KeyDescriptions.
      final validation = await client.remoteKeys.validate(
        session: sessionToken,
        code: code,
      );
      if (validation.remoteKey.isEmpty) {
        _error = '2FA validation returned no remote key';
        notifyListeners();
        return false;
      }
      if (validation.remoteKey != _remoteKeyId) {
        _remoteKeyId = validation.remoteKey;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsRemoteKeyId, _remoteKeyId!);
      }
      // Mint a fresh device share locally and run the Wallet:reshare
      // ceremony using the fresh RemoteKey session id.
      final wallet = await client.wallets.get(_walletId!);
      final priv = await _resharedDeviceShare(
        client: client,
        wallet: wallet,
        password: password,
        freshRemoteKeyResource: validation.remoteKey,
      );
      _storeKeyPriv = priv;
      _password = password;
      notifyListeners();
      unawaited(ensureSolanaDefault());
      return true;
    } catch (e) {
      _error = '2FA recovery failed: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// Reset the wallet password WITHOUT the old one, using the on-device
  /// StoreKey share + a 2FA-validated RemoteKey. Reshare committee
  /// `[StoreKey + RemoteKey] → [StoreKey(new) + Password(new) + RemoteKey]`.
  ///
  /// Preconditions: [loadWalletForRecovery] has loaded the target wallet and a
  /// RemoteKey session was started via [startRemoteKeyReshare] (its SMS/email
  /// code is [code]). The device StoreKey priv must be readable from the
  /// keystore WITHOUT a password — true when the OS keystore holds it (the
  /// normal case). When only the password-encrypted fallback blob survived
  /// (e.g. after a restore) this can't run, and the user must restore from a
  /// backup instead.
  ///
  /// On success the wallet is reshared, the new device share is persisted under
  /// [newPassword], and the wallet is left active + unlocked.
  Future<bool> resetPasswordVia2fa({
    required String sessionToken,
    required String code,
    required String newPassword,
  }) async {
    if (_walletId == null || _storeKeyId == null) {
      _error = 'No wallet loaded to reset';
      notifyListeners();
      return false;
    }
    if (newPassword.length < 8) {
      _error = 'New password must be at least 8 characters';
      notifyListeners();
      return false;
    }
    try {
      final client = await _getClient();
      // Device StoreKey priv, read WITHOUT the password (OS-keystore path).
      final storeKeyPriv =
          await _keystore.readDeviceShare(walletId: _walletId!);
      if (storeKeyPriv == null) {
        _error = "This device's wallet key isn't available without the "
            'password (e.g. after a restore). Restore from a backup instead.';
        notifyListeners();
        return false;
      }
      // Validate the 2FA code → fresh RemoteKey resource (the stored one is a
      // `done` session and can't authorize a reshare).
      final validation = await client.remoteKeys.validate(
        session: sessionToken,
        code: code,
      );
      if (validation.remoteKey.isEmpty) {
        _error = '2FA validation returned no remote key';
        notifyListeners();
        return false;
      }
      final freshRemote = validation.remoteKey;
      // Reshare: authorize with StoreKey + RemoteKey (no old password), set a
      // new Password. Mint a fresh StoreKey for the new committee.
      final wallet = await client.wallets.get(_walletId!);
      final newStorePair = await client.storeKeys.create();
      final oldKeys = buildReshareOldKeys(
        wallet: wallet,
        password: null,
        storeKeyPriv: storeKeyPriv,
        freshRemoteKeyResource: freshRemote,
      );
      WalletKey? oldRemoteKey;
      for (final k in wallet.keys) {
        if (k.type == 'RemoteKey') {
          oldRemoteKey = k;
          break;
        }
      }
      final newKeys = <KeyDescription>[
        KeyDescription.storeKey(newStorePair.publicKey),
        if (oldRemoteKey != null)
          KeyDescription(type: 'RemoteKey', key: freshRemote),
        KeyDescription.password(newPassword),
      ];
      Wallet? after;
      await for (final ev in client.wallets.reshare(
        _walletId!,
        oldKeys: oldKeys,
        newKeys: newKeys,
      )) {
        if (ev is Complete<Wallet>) after = ev.value;
      }
      if (after == null) {
        throw StateError('Password-reset reshare returned no wallet');
      }
      // Adopt the new committee + persist under the new password. The wallet
      // is now the active, unlocked one.
      final freshIds = _extractKeyIdsByType(after);
      _storeKeyId = freshIds['StoreKey'];
      _passwordKeyId = freshIds['Password'];
      _remoteKeyId = freshIds['RemoteKey'] ?? freshRemote;
      _storeKeyPriv = newStorePair.privateKey;
      _password = newPassword;
      await _persist(storeKeyPublic: newStorePair.publicKey);
      notifyListeners();
      unawaited(ensureSolanaDefault());
      return true;
    } catch (e) {
      _error = 'Password reset failed: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// Reshare the active wallet replacing the StoreKey share with a
  /// freshly-generated one. Useful when the user suspects the device
  /// share has been exposed and wants to invalidate it. Requires the
  /// wallet to be unlocked.
  Future<bool> rotateDeviceShare() async {
    if (!isUnlocked) {
      _error = 'Unlock the wallet first';
      notifyListeners();
      return false;
    }
    try {
      final client = await _getClient();
      final storePair = await client.storeKeys.create();

      final old = <KeyDescription>[];
      final fresh = <KeyDescription>[];
      final prefs = await SharedPreferences.getInstance();
      final oldStorePub = prefs.getString(_prefsStorePub);
      if (oldStorePub != null) old.add(KeyDescription.storeKey(oldStorePub));
      fresh.add(KeyDescription.storeKey(storePair.publicKey));
      if (_remoteKeyId != null) {
        old.add(KeyDescription.remoteKey(_remoteKeyId!));
        fresh.add(KeyDescription.remoteKey(_remoteKeyId!));
      }
      old.add(KeyDescription.password(_password!));
      fresh.add(KeyDescription.password(_password!));

      Wallet? after;
      await for (final ev in client.wallets.reshare(
        _walletId!,
        oldKeys: old,
        newKeys: fresh,
      )) {
        if (ev is Complete<Wallet>) after = ev.value;
      }
      if (after == null) {
        throw StateError('Reshare did not return a wallet');
      }

      // Swap the in-memory + persisted device share.
      _storeKeyPriv = storePair.privateKey;
      _storeKeyId = _extractKeyIdsByType(after)['StoreKey'];
      await prefs.setString(_prefsStorePub, storePair.publicKey);
      if (_storeKeyId != null) {
        await prefs.setString(_prefsStoreKeyId, _storeKeyId!);
      }
      await _keystore.writeDeviceShare(
        walletId: _walletId!,
        value: storePair.privateKey,
        password: _password!,
      );
      notifyListeners();
      unawaited(_maybeAutoBackup()); // device share changed — refresh backup
      return true;
    } catch (e) {
      _error = 'Rotate device share failed: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// Set [accountId] as the active account. Stage 1 supports switching only
  /// between accounts that share the same parent wallet — switching across
  /// wallets would require reloading a different wallet's TSS shares, which
  /// isn't wired yet. Returns true on success; sets [_error] and returns
  /// false otherwise.
  Future<bool> switchAccount(String accountId) async {
    if (accountId == _accountId) return true;
    try {
      final client = await _getClient();
      final acct = await client.accounts.get(accountId);
      if (acct.wallet != _walletId) {
        // Cross-wallet switches must switch the active wallet first (which
        // needs that wallet's password) — the UI drives that via
        // ensureUnlocked(walletId:) before calling switchAccount again.
        _error = 'Switch to that wallet first to use its accounts';
        notifyListeners();
        return false;
      }
      await client.accounts.setCurrent(accountId);
      _accountId = acct.id;
      _publicKey = acct.address;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsAccountId, _accountId!);
      await prefs.setString(_prefsAddress, _publicKey!);
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Account switch failed: $e';
      notifyListeners();
      return false;
    }
  }

  /// Pure routing decision for tapping an account. Used by the accounts UI
  /// and unit-tested directly. Picks: no-op, same-wallet `setCurrent`, or
  /// switch-the-parent-wallet-first then `setCurrent`.
  static AccountSwitchRoute accountSwitchRoute({
    required String targetAccountId,
    required String? currentAccountId,
    required String targetWalletId,
    required String? activeWalletId,
  }) {
    if (targetAccountId == currentAccountId) {
      return AccountSwitchRoute.alreadyCurrent;
    }
    if (targetWalletId == activeWalletId) return AccountSwitchRoute.sameWallet;
    return AccountSwitchRoute.crossWallet;
  }

  /// Pure routing decision for [switchWallet]. Extracted so it can be
  /// unit-tested without a libwallet client.
  @visibleForTesting
  static SwitchPlan planWalletSwitch({
    required bool targetIsActiveAndUnlocked,
    required bool hasLocalDeviceShare,
    required bool passwordProvided,
  }) {
    if (targetIsActiveAndUnlocked) return SwitchPlan.alreadyActive;
    if (!hasLocalDeviceShare) return SwitchPlan.needsRecovery;
    if (!passwordProvided) return SwitchPlan.needsPassword;
    return SwitchPlan.proceed;
  }

  /// Make [walletId] the active, unlocked wallet by reloading its TSS shares
  /// from libwallet + this device's per-wallet keystore entry. Validates
  /// [password] against the wallet's Password share and swaps the in-memory
  /// active state — which LOCKS the previously-active wallet (its
  /// `_password`/`_storeKeyPriv` are overwritten). Day-to-day signing is
  /// unchanged (StoreKey + Password). Returns a typed [SwitchResult] so the
  /// UI can prompt for a password or route to 2FA recovery.
  Future<SwitchResult> switchWallet(String walletId, {String? password}) async {
    // Already active: a StoreKey wallet that's unlocked, a D5 wallet (no
    // StoreKey), or any wallet under lockless signing (nothing to unlock).
    // Avoids a needless wallet fetch.
    if (_walletId == walletId &&
        (isUnlocked || _storeKeyId == null || kLocklessSigning)) {
      return SwitchResult.ok;
    }

    try {
      final client = await _getClient();
      final w = await client.wallets.get(walletId);
      final keyIds = _extractKeyIdsByType(w);
      final storeKeyId = keyIds['StoreKey'];
      final passwordKeyId = keyIds['Password'];

      // Free, password-free activation: a D5 (password-only) wallet always, or
      // ANY wallet under lockless signing. No device-share load, no password —
      // signing authorizes per-transaction via the sheet. StoreKey metadata is
      // kept; only the session secrets (_storeKeyPriv/_password) stay null.
      if (storeKeyId == null || kLocklessSigning) {
        final account = await _resolveAccount(client, w);
        await client.accounts.setCurrent(account.id);
        _walletId = walletId;
        _accountId = account.id;
        _publicKey = account.address;
        _walletName = w.name.isNotEmpty ? w.name : 'In-app wallet';
        _storeKeyId = storeKeyId;
        _remoteKeyId = keyIds['RemoteKey'];
        _passwordKeyId = passwordKeyId;
        _storeKeyPriv = null;
        _password = null;
        final storeKeyPub = storeKeyId == null
            ? null
            : w.keys.firstWhere((k) => k.type == 'StoreKey').key;
        await _persist(storeKeyPublic: storeKeyPub);
        notifyListeners();
        if (w.curve == 'ed25519') unawaited(ensureSolanaDefault());
        return SwitchResult.ok;
      }

      // StoreKey wallet: needs the device share + password.
      final hasShare = await _keystore.hasDeviceShare(walletId);
      final plan = planWalletSwitch(
        targetIsActiveAndUnlocked: _walletId == walletId && isUnlocked,
        hasLocalDeviceShare: hasShare,
        passwordProvided: password != null && password.isNotEmpty,
      );
      switch (plan) {
        case SwitchPlan.alreadyActive:
          return SwitchResult.ok;
        case SwitchPlan.needsRecovery:
          _error =
              'This wallet has no device share on this device. '
              'Recover it via 2FA, then try again.';
          notifyListeners();
          return SwitchResult.needsRecovery;
        case SwitchPlan.needsPassword:
          return SwitchResult.needsPassword;
        case SwitchPlan.proceed:
          break;
      }

      if (passwordKeyId == null) {
        _error = 'Wallet is missing required key shares';
        notifyListeners();
        return SwitchResult.error;
      }

      // Read THIS wallet's device share (keystore only — no libwallet FFI).
      // OS keystore needs no password; the fallback blob throws
      // WrongPasswordException on a bad password.
      String? priv;
      try {
        priv = await _keystore.readDeviceShare(
          walletId: walletId,
          password: password,
        );
      } on WrongPasswordException {
        _error = 'Wrong password for this wallet';
        notifyListeners();
        return SwitchResult.wrongPassword;
      }
      if (priv == null) {
        _error = "Could not read this wallet's device share";
        notifyListeners();
        return SwitchResult.error;
      }

      // Make this wallet's account current before deriving against it (so
      // libwallet's session points at the right wallet), and resolve a
      // curve-correct account — a mismatched account type would make the TSS
      // layer derive the wrong key type.
      final account = await _resolveAccount(client, w);
      await client.accounts.setCurrent(account.id);

      // Validate the password against the Password share without signing.
      try {
        await client.storeKeys.derivePassword(
          password: password!,
          walletKeyId: passwordKeyId,
        );
      } on LibwalletException {
        _error = 'Wrong password for this wallet';
        notifyListeners();
        return SwitchResult.wrongPassword;
      }

      // Swap the active in-memory set. Overwriting these fields locks the
      // previously-active wallet (its password + device share leave memory).
      _walletId = walletId;
      _accountId = account.id;
      _publicKey = account.address;
      _walletName = w.name.isNotEmpty ? w.name : 'In-app wallet';
      _storeKeyId = storeKeyId;
      _remoteKeyId = keyIds['RemoteKey'];
      _passwordKeyId = passwordKeyId;
      _storeKeyPriv = priv;
      _password = password;

      final storeKeyPub = w.keys.firstWhere((k) => k.type == 'StoreKey').key;
      await _persist(storeKeyPublic: storeKeyPub);
      notifyListeners();
      // Only normalize to Solana for ed25519 wallets — forcing it for a
      // secp256k1 wallet mismatches the account's curve.
      if (w.curve == 'ed25519') unawaited(ensureSolanaDefault());
      return SwitchResult.ok;
    } catch (e) {
      _error = 'Could not switch wallet: $e';
      debugPrint(_error);
      notifyListeners();
      return SwitchResult.error;
    }
  }

  /// Pick the account to activate for [wallet]: an existing Solana account if
  /// any, else the first existing account, else a freshly-derived default
  /// account whose type MATCHES the wallet's curve (ed25519 → solana,
  /// otherwise → ethereum). Creating a mismatched account type makes
  /// libwallet's TSS layer derive the wrong key type and crash.
  Future<Account> _resolveAccount(LibwalletClient client, Wallet wallet) async {
    final accounts = await client.accounts.list(wallet: wallet.id);
    if (accounts.isNotEmpty) {
      for (final a in accounts) {
        if (a.type == 'solana') return a;
      }
      return accounts.first;
    }
    final isEd = wallet.curve == 'ed25519';
    return client.accounts.create(
      name: isEd ? 'Solana' : 'Ethereum',
      wallet: wallet.id,
      type: isEd ? 'solana' : 'ethereum',
      index: 0,
    );
  }

  /// Load [walletId]'s metadata into the active slot as active-but-LOCKED
  /// (no device share / password). Overwriting the active fields locks the
  /// previously-active wallet. Used by the 2FA recovery entry and after
  /// removing the active wallet.
  Future<bool> _loadWalletLocked(String walletId) async {
    try {
      final client = await _getClient();
      final w = await client.wallets.get(walletId);
      final keyIds = _extractKeyIdsByType(w);
      final account = await _resolveAccount(client, w);
      _walletId = walletId;
      _accountId = account.id;
      _publicKey = account.address;
      _walletName = w.name.isNotEmpty ? w.name : 'In-app wallet';
      _storeKeyId = keyIds['StoreKey'];
      _remoteKeyId = keyIds['RemoteKey'];
      _passwordKeyId = keyIds['Password'];
      _storeKeyPriv = null;
      _password = null;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Could not load wallet: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// Load a wallet (active-but-locked) so the 2FA recovery flow can mint a
  /// fresh device share for it. See [_loadWalletLocked].
  Future<bool> loadWalletForRecovery(String walletId) =>
      _loadWalletLocked(walletId);

  /// Pick the wallet to make active after [removedId] is removed: the first
  /// id in [walletIds] that isn't the removed one, or null if none remain.
  @visibleForTesting
  static String? pickNextActive(List<String> walletIds, String removedId) {
    for (final id in walletIds) {
      if (id != removedId) return id;
    }
    return null;
  }

  /// Remove [walletId] from this device: delete it from libwallet's local
  /// store and delete ITS per-wallet device share (other wallets are
  /// untouched). If it was the active wallet, the next remaining wallet
  /// becomes active-but-locked (the user unlocks it when needed), or the
  /// state clears to "no wallet" if none remain. Returns true on success.
  Future<bool> removeWallet(String walletId) async {
    try {
      final client = await _getClient();
      final wasActive = walletId == _walletId;
      await client.wallets.delete(walletId);
      await _keystore.deleteDeviceShare(walletId);
      if (wasActive) {
        final remaining = (await client.wallets.list())
            .map((w) => w.id)
            .toList();
        final nextId = pickNextActive(remaining, walletId);
        if (nextId != null) {
          await _loadWalletLocked(nextId);
          await _persistActivePointer();
        } else {
          _clearActiveFields();
          await _clearActivePrefs();
        }
      }
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Could not remove wallet: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// Rename [walletId] on the libwallet backend (PATCH `Wallet/<id>` with the
  /// new `Name`). libwallet imposes no naming convention — the name is an
  /// untrusted display string — so callers validate length up front (see
  /// [WalletDetailsScreen.validateWalletName]); [name] is trimmed defensively
  /// here. When the renamed wallet is the active one, the cached display name
  /// and its persisted pointer are refreshed so the home header / wallet list
  /// reflect the change immediately. Returns true on success.
  Future<bool> renameWallet(String walletId, String name) async {
    final trimmed = name.trim();
    try {
      final client = await _getClient();
      final updated = await client.wallets.update(walletId, name: trimmed);
      if (walletId == _walletId) {
        _walletName = updated.name.isNotEmpty ? updated.name : trimmed;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsName, _walletName!);
      }
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Could not rename wallet: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  void _clearActiveFields() {
    _publicKey = null;
    _walletId = null;
    _accountId = null;
    _walletName = null;
    _storeKeyPriv = null;
    _storeKeyId = null;
    _remoteKeyId = null;
    _passwordKeyId = null;
    _password = null;
  }

  Future<void> _clearActivePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in const [
      _prefsWalletId,
      _prefsAccountId,
      _prefsAddress,
      _prefsStorePub,
      _prefsStorePriv,
      _prefsStoreKeyId,
      _prefsRemoteKeyId,
      _prefsPasswordKeyId,
      _prefsName,
    ]) {
      await prefs.remove(key);
    }
  }

  Future<void> _persistActivePointer() async {
    final prefs = await SharedPreferences.getInstance();
    final entries = <String, String?>{
      _prefsWalletId: _walletId,
      _prefsAccountId: _accountId,
      _prefsAddress: _publicKey,
      _prefsName: _walletName,
      _prefsStoreKeyId: _storeKeyId,
      _prefsRemoteKeyId: _remoteKeyId,
      _prefsPasswordKeyId: _passwordKeyId,
    };
    for (final e in entries.entries) {
      final v = e.value;
      if (v != null) await prefs.setString(e.key, v);
    }
  }

  /// Forget session secrets. Wallet metadata persists; user must unlock again
  /// before signing.
  void lock() {
    _storeKeyPriv = null;
    _password = null;
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    final id = _walletId;
    try {
      if (id != null) {
        final client = await _getClient();
        await client.wallets.delete(id);
      }
    } catch (e) {
      debugPrint('Delete libwallet wallet failed: $e');
    }
    _publicKey = null;
    _walletId = null;
    _accountId = null;
    _walletName = null;
    _storeKeyPriv = null;
    _storeKeyId = null;
    _remoteKeyId = null;
    _passwordKeyId = null;
    _password = null;
    _error = null;

    final prefs = await SharedPreferences.getInstance();
    for (final key in const [
      _prefsWalletId,
      _prefsAccountId,
      _prefsAddress,
      _prefsStorePub,
      _prefsStorePriv,
      _prefsStoreKeyId,
      _prefsRemoteKeyId,
      _prefsPasswordKeyId,
      _prefsName,
      _prefsNetworkPicked,
    ]) {
      await prefs.remove(key);
    }
    if (id != null) await _keystore.deleteDeviceShare(id);
    notifyListeners();
  }

  @override
  Future<Uint8List?> signMessage(Uint8List message) async {
    if (!_ensureReady()) return null;
    try {
      final client = await _getClient();
      final result = await client.accounts.signMessage(
        _accountId!,
        message: message,
        keys: _signingKeys(),
        mode: 'solana',
      );
      return base58Decode(result.signature);
    } catch (e) {
      _error = 'Message signing failed: $e';
      debugPrint(_error);
      notifyListeners();
      return null;
    }
  }

  @override
  Future<List<Uint8List?>> signTransactions(
    List<Uint8List> transactions,
  ) async {
    if (!_ensureReady()) return List.filled(transactions.length, null);
    final client = await _getClient();
    final keys = _signingKeys();
    final out = <Uint8List?>[];
    for (final tx in transactions) {
      try {
        final signed = await client.accounts.signTransaction(
          _accountId!,
          transaction: tx,
          keys: keys,
        );
        out.add(signed);
      } catch (e) {
        debugPrint('signTransactions error: $e');
        out.add(null);
      }
    }
    return out;
  }

  @override
  Future<List<String?>> signAndSendTransactions(
    List<Uint8List> transactions,
  ) async {
    if (!_ensureReady()) return List.filled(transactions.length, null);
    final client = await _getClient();
    final keys = _signingKeys();
    final out = <String?>[];
    for (final tx in transactions) {
      try {
        final sig = await client.accounts.signAndSendTransaction(
          _accountId!,
          transaction: tx,
          keys: keys,
        );
        out.add(sig);
      } catch (e) {
        debugPrint('signAndSendTransactions error: $e');
        out.add(null);
      }
    }
    return out;
  }

  @override
  void clearError() {
    _error = null;
    notifyListeners();
  }

  // --- wallet dashboard APIs ---

  /// List assets for the current account (SOL + SPL tokens). Passes
  /// `convert: 'USD'` so each Asset comes back with `fiatAmount` populated
  /// for the dashboard's per-token USD column.
  Future<List<Asset>> getAssets({String convert = 'USD'}) async {
    final client = await _getClient();
    return client.assets.list(convert: convert);
  }

  /// List recent transactions, newest first. When [forAddress] is
  /// provided, only rows where the address appears as sender OR
  /// recipient are returned — libwallet's local transaction table is
  /// shared across every wallet ever created on this device, and the
  /// `from:` server filter on `transactions.list` is a sender-address
  /// match (so it loses incoming txs). Filtering client-side here is
  /// the only way to scope the dashboard to the active wallet.
  ///
  /// If the first page comes back with zero matches but is full (the
  /// active wallet's history sits past the newest 50 rows of the
  /// shared table — e.g. another wallet on this device has generated
  /// a flood of recent activity), we walk back up to [maxPages] more
  /// pages via the `before:` cursor before giving up. Each call still
  /// terminates: pagination stops as soon as a page returns fewer
  /// than [limit] rows.
  Future<List<Transaction>> getTransactions({
    int limit = 50,
    String? forAddress,
    int maxPages = 5,
  }) async {
    final client = await _getClient();
    final firstPage = await client.transactions.list(
      convert: 'USD',
      limit: limit,
    );
    if (forAddress == null || forAddress.isEmpty) return firstPage;

    // Case-insensitive match: defensive against libwallet ever returning
    // EVM addresses in non-checksum form. No-op for Solana (base58 is
    // case-significant, so the lowercased values still match the
    // lowercased user address byte-for-byte).
    final me = forAddress.toLowerCase();
    bool isMine(Transaction t) =>
        t.from.toLowerCase() == me || t.to.toLowerCase() == me;
    final matches = firstPage.where(isMine).toList();
    if (matches.isNotEmpty || firstPage.length < limit) return matches;

    // Cold start for an underused wallet: nothing on the first page
    // matched, but the page was full — walk back through older pages
    // until we find some matches or run out of history.
    var lastPage = firstPage;
    for (var i = 0; i < maxPages; i++) {
      final before = lastPage.last.created?.toIso8601String();
      if (before == null) break;
      final next = await client.transactions.list(
        convert: 'USD',
        limit: limit,
        before: before,
      );
      if (next.isEmpty) break;
      matches.addAll(next.where(isMine));
      if (matches.isNotEmpty) return matches;
      if (next.length < limit) break;
      lastPage = next;
    }
    return matches;
  }

  /// Cache of curated-token lists keyed by chainKey
  /// (`"<type>.<chainId>"`). `listCurated` is local but still pays
  /// JSON-decode cost on every call, and the list is stable within a
  /// session.
  final Map<String, List<CuratedToken>> _curatedCache = {};

  /// Search libwallet's embedded curated-token registry by
  /// case-insensitive substring match on symbol, name, or address.
  /// Purely local — no RPC, no third-party HTTP. Backed by the
  /// vetted per-chain list libwallet ships (Jupiter verified list
  /// for Solana, Uniswap default list for EVM, etc.).
  ///
  /// [network] defaults to the active wallet's current network's
  /// chainKey. If no network is loaded yet, returns an empty list.
  Future<List<TokenSearchResult>> searchCuratedTokens(
    String query, {
    String? network,
    int limit = 20,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final chainKey = network ?? _curatedChainKey();
    if (chainKey == null) return const [];
    final tokens = await _loadCurated(chainKey);
    final results = <TokenSearchResult>[];
    for (final t in tokens) {
      if (t.symbol.toLowerCase().contains(q) ||
          t.name.toLowerCase().contains(q) ||
          t.address.toLowerCase().contains(q)) {
        results.add(
          TokenSearchResult(
            mint: t.address,
            name: t.name,
            symbol: t.symbol,
            imageUrl: t.logoUri.isEmpty ? null : t.logoUri,
            decimals: t.decimals,
          ),
        );
        if (results.length >= limit) break;
      }
    }
    return results;
  }

  String? _curatedChainKey() {
    final n = _currentNetwork;
    if (n == null) return null;
    return '${n.type.name}.${n.chainId}';
  }

  Future<List<CuratedToken>> _loadCurated(String chainKey) async {
    final cached = _curatedCache[chainKey];
    if (cached != null) return cached;
    try {
      final client = await _getClient();
      final list = await client.tokens.listCurated(chainKey);
      _curatedCache[chainKey] = list;
      return list;
    } catch (e) {
      debugPrint('listCurated($chainKey) failed: $e');
      return const [];
    }
  }

  /// Re-fire libwallet's background tx-history backfill for the active
  /// account. The backfill is normally triggered automatically on env
  /// init / Account:setCurrent / Network:setCurrent — but if the original
  /// init-time attempt failed silently (RPC hiccup, daemon offline at
  /// that instant) `transactions.list` keeps returning the empty local
  /// table until the next setCurrent. Calling this re-fires the trigger;
  /// new rows arrive via the `txHistoryUpdates` stream.
  Future<void> kickHistoryBackfill() async {
    final accountId = _accountId;
    if (accountId == null) {
      debugPrint('[txhist] kickHistoryBackfill: no accountId, skipping');
      return;
    }
    debugPrint(
      '[txhist] kickHistoryBackfill: calling accounts.setCurrent($accountId)',
    );
    try {
      final client = await _getClient();
      await client.accounts.setCurrent(accountId);
      debugPrint(
        '[txhist] kickHistoryBackfill: setCurrent returned — backfill triggered',
      );
    } catch (e) {
      debugPrint('[txhist] kickHistoryBackfill failed: $e');
    }
  }

  /// Compute the max sendable amount (accounting for fees + rent).
  Future<MaxSendableResult> maxSendable({String? asset, String? to}) async {
    final client = await _getClient();
    return client.transactions.maxSendable(
      from: _accountId,
      asset: asset,
      to: to,
    );
  }

  static const _prefsAutoBackupAt = 'libw_auto_backup_at';
  static const _autoBackupFileName = 'tibane_wallet_autobackup.json';

  /// Path to the auto-backup file inside the app's documents directory.
  /// On iOS this directory is auto-backed up via the system iCloud Backup
  /// setting; on Android via Google Auto Backup when allowBackup=true.
  Future<File> _autoBackupFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_autoBackupFileName');
  }

  /// Write an encrypted copy of the wallet to the app's auto-backed-up
  /// documents directory. Returns the timestamp on success, or null on
  /// failure (with [_error] populated).
  ///
  /// On iOS this file is uploaded to iCloud Backup when the user has
  /// "iCloud Backup" enabled for the device. On Android it's included in
  /// Google Auto Backup if the app's allowBackup flag is set. No extra
  /// entitlements are needed — only the device-level backup setting.
  Future<DateTime?> writeAutoBackup(String password) async {
    try {
      final json = await exportBackupJson(password);
      final file = await _autoBackupFile();
      await file.writeAsString(json, flush: true);
      final now = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsAutoBackupAt, now.toIso8601String());
      notifyListeners();
      return now;
    } catch (e) {
      _error = 'Auto-backup failed: $e';
      debugPrint(_error);
      notifyListeners();
      return null;
    }
  }

  /// Timestamp of the last successful auto-backup, or null if none yet.
  Future<DateTime?> lastAutoBackup() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_prefsAutoBackupAt);
    if (s == null) return null;
    return DateTime.tryParse(s);
  }

  /// Read the JSON content of the auto-backup file, or null if it's not
  /// present (e.g. fresh install on a device that hasn't restored yet).
  Future<String?> readAutoBackup() async {
    final file = await _autoBackupFile();
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (e) {
      _error = 'Read auto-backup failed: $e';
      notifyListeners();
      return null;
    }
  }

  /// Delete the on-disk auto-backup file and clear the recorded timestamp.
  /// Useful for "stop backing up" / "wipe local copy" flows.
  Future<void> clearAutoBackup() async {
    try {
      final file = await _autoBackupFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsAutoBackupAt);
    notifyListeners();
  }

  /// Best-effort: re-write the auto-backup with the cached password so the
  /// iCloud / Google copy stays current after a key-material change (password
  /// change, device- or 2FA-share rotation). Only runs when auto-backup is
  /// already enabled (the user has backed up at least once) — it never
  /// auto-enrolls a wallet. No-op when locked; never throws (writeAutoBackup
  /// swallows its own errors).
  Future<void> _maybeAutoBackup() async {
    final pw = _password;
    if (pw == null) return; // locked — can't export
    if (await lastAutoBackup() == null) return; // auto-backup not enabled
    await writeAutoBackup(pw);
  }

  /// Export the connected wallet's backup bundle as a pretty-printed JSON
  /// string. Re-validates the supplied [password] before exporting; throws
  /// `StateError` on bad password or missing wallet state.
  Future<String> exportBackupJson(String password) async {
    final walletId = _walletId;
    final passwordKeyId = _passwordKeyId;
    if (walletId == null || passwordKeyId == null) {
      throw StateError('No wallet to export');
    }
    final client = await _getClient();
    try {
      await client.storeKeys.derivePassword(
        password: password,
        walletKeyId: passwordKeyId,
      );
    } catch (_) {
      throw StateError('Wrong password');
    }
    final entries = await client.wallets.backup(walletId);
    final payload = entries.map((e) => e.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Restore a wallet from a previously exported backup JSON. The password
  /// must match the original wallet's password. On success the restored
  /// wallet becomes the active in-app wallet (state persisted, unlocked).
  ///
  /// Returns true on success. Note: the original device-share private key
  /// is not part of the backup — after import, signing flows will require
  /// re-establishing a fresh device share via reshare (out of scope here).
  Future<bool> importFromBackup({
    required String backupJson,
    required String password,
  }) async {
    if (hasWallet) {
      _error = 'Disconnect the current wallet before importing';
      notifyListeners();
      return false;
    }
    _connecting = true;
    _error = null;
    notifyListeners();
    Wallet? restored;
    LibwalletClient? client;
    try {
      final parsed = jsonDecode(backupJson);
      if (parsed is! List) {
        throw const FormatException('Expected a JSON array of backup entries');
      }
      if (parsed.isEmpty) {
        throw const FormatException('Backup is empty');
      }
      final files = <Map<String, String>>[];
      for (final raw in parsed) {
        if (raw is! Map) {
          throw const FormatException('Each entry must be an object');
        }
        final filename = raw['filename'];
        final data = raw['data'];
        if (filename is! String || data is! String) {
          throw const FormatException(
            'Each entry needs string filename and data',
          );
        }
        files.add({'filename': filename, 'data': data});
      }

      client = await _getClient();
      final before = (await client.wallets.list()).map((w) => w.id).toSet();
      await client.wallets.restore(files);
      final after = await client.wallets.list();
      for (final w in after) {
        if (!before.contains(w.id) && w.curve == 'ed25519') {
          restored = w;
          break;
        }
      }
      if (restored == null) {
        throw StateError('Backup contains no Solana (ed25519) wallet');
      }

      final accounts = await client.accounts.list(wallet: restored.id);
      debugPrint(
        'Import: restored wallet ${restored.id} (curve=${restored.curve}) '
        'has ${accounts.length} accounts: '
        '${accounts.map((a) => a.type).join(", ")}',
      );
      Account? account;
      for (final a in accounts) {
        if (a.type == 'solana') {
          account = a;
          break;
        }
      }
      // Accounts aren't part of the wallet backup — they're derived on
      // demand. If the restored wallet has no Solana account yet,
      // create one at index 0 (same as the fresh-create flow does).
      account ??= await client.accounts.create(
        name: 'Solana',
        wallet: restored.id,
        type: 'solana',
        index: 0,
      );

      final keyIds = _extractKeyIdsByType(restored);
      final passwordKeyId = keyIds['Password'];
      if (passwordKeyId == null) {
        throw StateError('Restored wallet has no Password share');
      }
      try {
        await client.storeKeys.derivePassword(
          password: password,
          walletKeyId: passwordKeyId,
        );
      } on LibwalletException {
        throw StateError('Wrong password for this backup');
      }

      _walletId = restored.id;
      _accountId = account.id;
      _publicKey = account.address;
      _walletName = restored.name.isNotEmpty ? restored.name : 'In-app wallet';
      _storeKeyId = keyIds['StoreKey'];
      _remoteKeyId = keyIds['RemoteKey'];
      _passwordKeyId = passwordKeyId;
      _password = password;
      _storeKeyPriv = null;

      // Cross-device imports leave _storeKeyPriv null intentionally —
      // the device-share Keychain/Keystore entry from the source
      // device doesn't transfer. First unlock on this device will
      // detect the gap and route the user through the 2FA recovery
      // screen, which runs `_resharedDeviceShare` to mint a fresh
      // device share locally.

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsWalletId, _walletId!);
      await prefs.setString(_prefsAccountId, _accountId!);
      await prefs.setString(_prefsAddress, _publicKey!);
      await prefs.setString(_prefsName, _walletName!);
      if (_storeKeyId != null) {
        await prefs.setString(_prefsStoreKeyId, _storeKeyId!);
      }
      if (_remoteKeyId != null) {
        await prefs.setString(_prefsRemoteKeyId, _remoteKeyId!);
      }
      await prefs.setString(_prefsPasswordKeyId, _passwordKeyId!);
      notifyListeners();
      return true;
    } catch (e) {
      // Clean up any wallet that landed in libwallet's local store before
      // a downstream check failed — otherwise a retry sees stale "new"
      // wallets and may pick the wrong one.
      if (restored != null && client != null) {
        try {
          await client.wallets.delete(restored.id);
        } catch (cleanupErr) {
          debugPrint('Import cleanup failed: $cleanupErr');
        }
      }
      _error = 'Import failed: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  /// Simulate a send (transfer) without broadcasting. Returns the
  /// [TransactionSimulation] for use in an approval-sheet review step:
  /// expected balance changes, recipient_new_account warnings, etc. The
  /// wallet doesn't need to be unlocked — simulation requires no key
  /// material.
  Future<TransactionSimulation> simulateSend({
    required String to,
    required Amount amount,
    String? asset,
  }) async {
    final client = await _getClient();
    final resolvedAsset = await _resolveAssetKey(client, asset);
    final tx = UnsignedTransaction(
      type: 'transfer',
      to: to,
      from: _accountId,
      amount: amount,
      asset: resolvedAsset,
      priorityLevel: 'medium',
    );
    // `validate` is the authoritative pre-flight: it builds the tx and throws
    // on real problems (insufficient funds, bad recipient, rent). It runs the
    // same RPCs simulate would (balance, rent-exemption, account info, fees).
    await client.transactions.validate(tx);
    // `simulate` is best-effort enrichment (compute units, program-log
    // warnings). On Solana it can't run from an UnsignedTransaction — the
    // backend errors "solana tx has no raw bytes; call validate first"
    // because validate's built raw tx isn't carried back into simulate (the
    // UnsignedTransaction has no raw field). Since validate already vetted
    // the tx, degrade gracefully to a benign preview instead of failing.
    try {
      return await client.transactions.simulate(tx);
    } catch (e) {
      debugPrint('simulate unavailable (validate already vetted tx): $e');
      return const TransactionSimulation(chain: 'solana', willRevert: false);
    }
  }

  /// Send SOL or an SPL token. Returns the broadcast transaction.
  Future<Transaction> send({
    required String to,
    required Amount amount,
    String? asset,
  }) async {
    final client = await _getClient();
    final keys = _signingKeys()
        .map(
          (k) => SigningKey(
            id: k['Id'] as String,
            key: k['Key'] as String,
            type: k['Type'] as String?,
          ),
        )
        .toList();
    final resolvedAsset = await _resolveAssetKey(client, asset);
    final tx = UnsignedTransaction(
      type: 'transfer',
      to: to,
      from: _accountId,
      amount: amount,
      asset: resolvedAsset,
      priorityLevel: 'medium',
    );
    // `validate` requires an explicit asset and surfaces any build/funding
    // problem before we pull signing keys; signAndSend then builds, signs,
    // and broadcasts.
    await client.transactions.validate(tx);
    return client.transactions.signAndSendSimple(tx, keys: keys);
  }

  // ------------------------------------------------------------------
  // Per-transaction (lockless) signing — Phase 1 (ATONLINE_PARITY §4.3 / §3.2).
  // These run IN PARALLEL with unlock()/lock()/_signingKeys()/send(): they
  // collect shares per call instead of from the cached session, never touch
  // the _storeKeyPriv/_password caches, and skip _ensureReady()'s unlock gate.
  // Reached only via the sign sheet when kLocklessSigning is on.
  // ------------------------------------------------------------------

  /// Fetch the current wallet record (its key shares + threshold) for the
  /// per-transaction sign sheet. Null when no in-app wallet exists.
  Future<Wallet?> currentWallet() async {
    if (_walletId == null) return null;
    final client = await _getClient();
    return client.wallets.get(_walletId!);
  }

  /// Resolve [storeKey]'s private share via the §3.2 fallback chain — used by
  /// the sign sheet and by any not-yet-migrated wallet:
  ///   1. `biometric_storage` (post-migration / biometric-created wallets),
  ///   2. the no-auth OS keystore copy (no password),
  ///   3. the password-encrypted recovery blob ([password] required, D8).
  /// Returns null when none of the three holds it (caller → 2FA recovery, §4.8).
  Future<String?> readStoreKeyPrivate(
    WalletKey storeKey, {
    String? password,
  }) async {
    if (_walletId == null) return null;
    // 1. biometric-gated copy (triggers a biometric prompt; null on cancel /
    //    when there's no entry — Phase-1 wallets aren't here yet).
    try {
      final bio = await Biometric.askSecuredKey(storeKey.key);
      if (bio != null && bio.isNotEmpty) return bio;
    } catch (e) {
      debugPrint('readStoreKeyPrivate biometric: $e');
    }
    // 2. no-auth OS keystore copy (no password needed).
    final noAuth = await _keystore.readDeviceShare(
      walletId: _walletId!,
      password: null,
    );
    if (noAuth != null) return noAuth;
    // 3. password-encrypted recovery blob — needs the typed password.
    if (password != null) {
      return _keystore.readDeviceShare(
        walletId: _walletId!,
        password: password,
      );
    }
    return null;
  }

  /// Send SOL or an SPL token using pre-collected per-transaction [keys] (from
  /// the sign sheet) instead of the cached session. Mirrors [send] but needs
  /// no app-level unlock. Returns the broadcast transaction.
  Future<Transaction> sendWithKeys({
    required String to,
    required Amount amount,
    String? asset,
    required List<SigningKey> keys,
  }) async {
    final client = await _getClient();
    final resolvedAsset = await _resolveAssetKey(client, asset);
    final tx = UnsignedTransaction(
      type: 'transfer',
      to: to,
      from: _accountId,
      amount: amount,
      asset: resolvedAsset,
      priorityLevel: 'medium',
    );
    await client.transactions.validate(tx);
    return client.transactions.signAndSendSimple(tx, keys: keys);
  }

  /// Sign [message] with pre-collected per-transaction [keys] (from the sign
  /// sheet). Lockless analogue of [signMessage] — no app-level unlock.
  Future<Uint8List?> signMessageWithKeys(
    Uint8List message,
    List<SigningKey> keys,
  ) async {
    if (_accountId == null) return null;
    try {
      final client = await _getClient();
      final result = await client.accounts.signMessage(
        _accountId!,
        message: message,
        keys: keys.map((k) => k.toJson()).toList(),
        mode: 'solana',
      );
      return base58Decode(result.signature);
    } catch (e) {
      _error = 'Message signing failed: $e';
      debugPrint(_error);
      notifyListeners();
      return null;
    }
  }

  /// Sign (only) each tx with pre-collected [keys]. Lockless analogue of
  /// [signTransactions] — collect the keys ONCE and reuse across the batch.
  Future<List<Uint8List?>> signTransactionsWithKeys(
    List<Uint8List> transactions,
    List<SigningKey> keys,
  ) async {
    if (_accountId == null) return List.filled(transactions.length, null);
    final client = await _getClient();
    final keyMaps = keys.map((k) => k.toJson()).toList();
    final out = <Uint8List?>[];
    for (final tx in transactions) {
      try {
        final signed = await client.accounts.signTransaction(
          _accountId!,
          transaction: tx,
          keys: keyMaps,
        );
        out.add(signed);
      } catch (e) {
        debugPrint('signTransactionsWithKeys error: $e');
        out.add(null);
      }
    }
    return out;
  }

  /// Sign + broadcast each tx with pre-collected [keys]. Lockless analogue of
  /// [signAndSendTransactions] — collect the keys ONCE and reuse across the
  /// batch.
  Future<List<String?>> signAndSendTransactionsWithKeys(
    List<Uint8List> transactions,
    List<SigningKey> keys,
  ) async {
    if (_accountId == null) return List.filled(transactions.length, null);
    final client = await _getClient();
    final keyMaps = keys.map((k) => k.toJson()).toList();
    final out = <String?>[];
    for (final tx in transactions) {
      try {
        final sig = await client.accounts.signAndSendTransaction(
          _accountId!,
          transaction: tx,
          keys: keyMaps,
        );
        out.add(sig);
      } catch (e) {
        debugPrint('signAndSendTransactionsWithKeys error: $e');
        out.add(null);
      }
    }
    return out;
  }

  /// Resolve the canonical asset key for a transfer. SPL transfers pass an
  /// explicit `solana.mainnet.<mint>` key; native SOL passes null, which
  /// libwallet's `validate` rejects ("asset is required"), so fill in the
  /// network's native key `<type>.<chainId>.NATIVE` (e.g. solana.mainnet.NATIVE).
  Future<String> _resolveAssetKey(LibwalletClient client, String? asset) async {
    if (asset != null && asset.isNotEmpty) return asset;
    final net = _currentNetwork ?? await client.networks.getCurrent();
    _currentNetwork = net;
    return '${net.type.name}.${net.chainId}.NATIVE';
  }

  // ------------------------------------------------------------------
  // Device transfer — RECEIVE side (this device = the new phone)
  // ------------------------------------------------------------------

  /// Receive a wallet pushed from another device over libwallet's
  /// device-transfer channel. [pairingCode] is the raw
  /// `tibane://device-transfer?…` string scanned from the OLD device's QR.
  ///
  /// Blocks (up to ~2 min) while the old device's user confirms; on success
  /// the wallet — including its StoreKey device share — lands in libwallet's
  /// local store (so it appears in `client.wallets.list()`) and the share is
  /// held in the PENDING slot. The active wallet is untouched: a received
  /// wallet is ADDED, never swapped in. Call [activateAfterTransfer] with the
  /// wallet password to validate it, persist its per-wallet device share, and
  /// (optionally) make it active.
  ///
  /// Returns true on success. On failure [error] carries a friendly message.
  Future<bool> importViaDeviceTransfer(String pairingCode) async {
    if (hasPendingTransfer) {
      _error = 'A received wallet is already awaiting its password.';
      notifyListeners();
      return false;
    }
    _connecting = true;
    _error = null;
    notifyListeners();
    DeviceTransferImportResult? result;
    LibwalletClient? client;
    try {
      client = await _getClient();
      // Blocks until the old device confirms (or a coded error fires).
      result = await client.wallets.importFromDevice(pairingCode);

      final wallet = await client.wallets.get(result.walletId);
      final keyIds = _extractKeyIdsByType(wallet);
      // Acceptance gate (curve / required shares / device share present).
      final storeKeyId = validateTransferAcceptance(
        curve: wallet.curve,
        keyIdsByType: keyIds,
        deviceShareKeyIds:
            result.deviceShares.map((d) => d.walletKeyId).toSet(),
      );
      final passwordKeyId = keyIds['Password']!; // validated non-null above
      // The transferred device share must belong to this wallet's StoreKey
      // (guaranteed present by validateTransferAcceptance above).
      final share =
          result.deviceShares.firstWhere((d) => d.walletKeyId == storeKeyId);

      final accounts = await client.accounts.list(wallet: wallet.id);
      Account? account;
      for (final a in accounts) {
        if (a.type == 'solana') {
          account = a;
          break;
        }
      }
      // Accounts aren't part of the transfer — derive one at index 0 if the
      // wallet arrived without a Solana account (mirrors create).
      account ??= await client.accounts.create(
        name: 'Solana',
        wallet: wallet.id,
        type: 'solana',
        index: 0,
      );

      // Stash what activate needs in the PENDING slot — active wallet stays
      // put. The account was derived above so switchWallet can resolve it.
      _pendingWalletId = wallet.id;
      _pendingName = wallet.name.isNotEmpty ? wallet.name : 'In-app wallet';
      _pendingPasswordKeyId = passwordKeyId;
      _pendingStoreKeyPriv = share.privateKey;
      notifyListeners();
      return true;
    } catch (e) {
      // Roll back any wallet that landed locally before a downstream check
      // failed, and clear partial pending state.
      if (result != null && client != null) {
        try {
          await client.wallets.delete(result.walletId);
        } catch (cleanupErr) {
          debugPrint('Device-transfer cleanup failed: $cleanupErr');
        }
      }
      _clearPendingTransfer();
      _error = friendlyTransferError(e);
      debugPrint('[device-transfer] failed: $e');
      notifyListeners();
      return false;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  /// Finish a device transfer started by [importViaDeviceTransfer]: validate
  /// the wallet [password], persist the transferred device share under the
  /// NEW wallet's id (per-wallet keystore), and — when [makeActive] is true
  /// (or this is the only wallet) — switch to it. When [makeActive] is false
  /// the wallet is left in the list, unlockable later, and the active wallet
  /// is unchanged. Returns true once the wallet is added.
  Future<bool> activateAfterTransfer(
    String password, {
    required bool makeActive,
  }) async {
    final walletId = _pendingWalletId;
    final passwordKeyId = _pendingPasswordKeyId;
    final storeKeyPriv = _pendingStoreKeyPriv;
    if (walletId == null || passwordKeyId == null || storeKeyPriv == null) {
      _error = 'No transferred wallet to activate';
      debugPrint('[device-transfer] activate: $_error');
      notifyListeners();
      return false;
    }
    try {
      final client = await _getClient();
      try {
        // Validate the password against the Password share without signing.
        await client.storeKeys.derivePassword(
          password: password,
          walletKeyId: passwordKeyId,
        );
      } on LibwalletException catch (e) {
        _error = 'Wrong password for this wallet';
        debugPrint('[device-transfer] activate: password validation failed: $e');
        notifyListeners();
        return false;
      }
      // Persist the transferred device share under the NEW wallet's id, keyed
      // per-wallet so it never touches the active wallet's share.
      await _keystore.writeDeviceShare(
        walletId: walletId,
        value: storeKeyPriv,
        password: password,
      );
      final hadActive = hasWallet;
      _clearPendingTransfer();
      // Promote to active when asked, or unconditionally when this is the
      // first/only wallet (nothing else to keep active). Reuses the tested
      // switchWallet path, which loads the just-written per-wallet share,
      // re-validates the password, and persists the active pointer.
      if (makeActive || !hadActive) {
        final res = await switchWallet(walletId, password: password);
        if (res != SwitchResult.ok) {
          _error = 'Wallet added, but activating it failed — '
              'open it from the wallet list.';
          debugPrint(
            '[device-transfer] activate: switchWallet returned $res '
            '(wallet $walletId added but not made active)',
          );
          notifyListeners();
          return true; // the wallet IS added; activation is best-effort
        }
      }
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Could not activate wallet: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// Discard a wallet received via [importViaDeviceTransfer] that was never
  /// activated (no password entered). Deletes it from libwallet's local store
  /// and clears the pending state, so a cancelled transfer leaves nothing
  /// behind. No-op unless a pending un-activated transfer exists. The active
  /// wallet is never touched.
  Future<void> abandonPendingTransfer() async {
    final id = _pendingWalletId;
    if (id == null) return;
    _clearPendingTransfer();
    try {
      final client = await _getClient();
      await client.wallets.delete(id);
    } catch (e) {
      debugPrint('abandonPendingTransfer cleanup failed: $e');
    }
    notifyListeners();
  }

  void _clearPendingTransfer() {
    _pendingWalletId = null;
    _pendingName = null;
    _pendingPasswordKeyId = null;
    _pendingStoreKeyPriv = null;
  }

  /// Acceptance gate for a wallet arriving over device transfer, extracted so
  /// the curve / required-share / device-share checks are unit-testable
  /// without a live client. Returns the StoreKey share id (the share that must
  /// travel) on success; throws [StateError] with a user-facing message —
  /// which [friendlyTransferError] passes through verbatim — on rejection.
  @visibleForTesting
  static String validateTransferAcceptance({
    required String curve,
    required Map<String, String> keyIdsByType,
    required Set<String> deviceShareKeyIds,
  }) {
    if (curve != 'ed25519') {
      throw StateError('Transferred wallet is not a Solana (ed25519) wallet');
    }
    final passwordKeyId = keyIdsByType['Password'];
    final storeKeyId = keyIdsByType['StoreKey'];
    if (passwordKeyId == null || storeKeyId == null) {
      throw StateError('Transferred wallet is missing required key shares');
    }
    if (!deviceShareKeyIds.contains(storeKeyId)) {
      throw StateError("Transfer did not include this wallet's device share");
    }
    return storeKeyId;
  }

  /// Map a device-transfer failure to a user-facing message. The libwallet
  /// FFI surfaces the wire code inside [LibwalletException.message]. Static +
  /// pure so the UI can reuse it and it's unit-testable without a client.
  static String friendlyTransferError(Object e) {
    if (e is StateError) return e.message;
    if (e is LibwalletException) {
      final m = e.message;
      bool has(String c) => m == c || m.contains(c);
      if (has('local_offline')) {
        return "This device isn't connected to the transfer network yet. "
            'Check your internet connection and try again in a moment.';
      }
      if (has('url_malformed') || has('token_invalid')) {
        return 'That QR code is not a valid device-transfer code.';
      }
      if (has('token_expired')) {
        return 'The transfer code expired. Generate a new one on the '
            'other device.';
      }
      if (has('declined')) {
        return 'The transfer was declined on the other device.';
      }
      if (has('timeout')) {
        return 'The other device did not confirm in time. Try again.';
      }
      if (has('peer_unreachable')) {
        return "Couldn't reach the other device. Make sure both are online.";
      }
      if (has('session_not_found')) {
        return 'That transfer session is no longer active. Start a new one.';
      }
      return 'Transfer failed: $m';
    }
    return 'Transfer failed: $e';
  }

  // ------------------------------------------------------------------
  // Device transfer — SEND side (this device = the old/source phone)
  // ------------------------------------------------------------------

  /// Pure routing for the device-transfer SEND screen, extracted for tests.
  /// Decides what must happen before [targetWalletId]'s StoreKey share can be
  /// released: switch to it, unlock it, or export straight away.
  static DeviceTransferSendRoute deviceTransferSendRoute({
    required String? activeWalletId,
    required String targetWalletId,
    required bool isUnlocked,
  }) {
    if (activeWalletId != targetWalletId) {
      return DeviceTransferSendRoute.switchFirst;
    }
    if (!isUnlocked) return DeviceTransferSendRoute.unlockFirst;
    return DeviceTransferSendRoute.exportDirectly;
  }

  /// Open a device-to-device transfer session for [walletId]. The caller
  /// paints [DeviceTransferSession.pairingCode] as a QR; the new device scans
  /// it and calls importFromDevice. Requires [walletId] to be the active,
  /// unlocked wallet — the StoreKey share must be in memory to release it at
  /// confirm time (the send screen switches/unlocks first). 5-minute,
  /// single-use session.
  Future<DeviceTransferSession> startDeviceTransferExport(
    String walletId, {
    String? storeKeyPriv,
  }) async {
    if (_walletId != walletId) {
      throw StateError(
        'This wallet is not the active one — open it first, then transfer',
      );
    }
    // Lockless passes the share collected on-demand; legacy uses the cached
    // session. Either way the share must be available to release at confirm.
    if (_storeKeyId == null || (storeKeyPriv ?? _storeKeyPriv) == null) {
      throw StateError('Could not read the device key to transfer it');
    }
    final client = await _getClient();
    return client.wallets.exportToDevice(walletId);
  }

  /// Read the ACTIVE wallet's StoreKey private via the §3.2 fallback chain
  /// (biometric → no-auth keystore → password blob). Used by lockless flows
  /// that must release/use the device share without a cached session (e.g.
  /// device-transfer export). Null when there's no StoreKey or the read fails.
  Future<String?> readActiveStoreKeyPrivate() async {
    final w = await currentWallet();
    if (w == null) return null;
    final storeKeys = w.keys.where((k) => k.type == 'StoreKey');
    if (storeKeys.isEmpty) return null;
    return readStoreKeyPrivate(storeKeys.first);
  }

  /// Approve a pending transfer after the new device connected
  /// (`wallet:transfer:pair_received`). Releases this device's StoreKey share
  /// so the new device ends up with a full, signable wallet — no reshare.
  /// Requires the wallet to still be unlocked.
  Future<void> confirmDeviceTransferExport(
    String sid, {
    String? storeKeyPriv,
  }) async {
    final storeKeyId = _storeKeyId;
    final priv = storeKeyPriv ?? _storeKeyPriv;
    if (storeKeyId == null || priv == null) {
      throw StateError('Could not read the device key to release it');
    }
    final client = await _getClient();
    final entry = DeviceShareEntry(
      walletKeyId: storeKeyId,
      privateKey: priv,
    );
    await client.wallets.exportToDeviceConfirm(sid: sid, deviceShares: [entry]);
  }

  /// Cancel / decline a pending transfer session. Best-effort and idempotent —
  /// the waiting new device receives a `declined` error.
  Future<void> cancelDeviceTransferExport(String sid) async {
    try {
      final client = await _getClient();
      await client.wallets.exportToDeviceCancel(sid);
    } catch (e) {
      debugPrint('[device-transfer] cancel failed for sid=$sid: $e');
    }
  }

  @override
  void dispose() {
    _balanceSub?.cancel();
    _logSub?.cancel();
    balanceTick.dispose();
    super.dispose();
  }

  // --- internals ---

  bool _ensureReady() {
    if (!hasWallet) {
      _error = 'No in-app wallet';
      notifyListeners();
      return false;
    }
    if (!isUnlocked) {
      _error = 'Wallet is locked — enter password';
      notifyListeners();
      return false;
    }
    return true;
  }

  List<Map<String, dynamic>> _signingKeys() {
    // 2-of-3: device StoreKey + Password. Server share is held in reserve
    // for recovery on a new device and is not required for day-to-day signing.
    final keys = <Map<String, dynamic>>[];
    if (_storeKeyId != null && _storeKeyPriv != null) {
      keys.add({'Id': _storeKeyId, 'Key': _storeKeyPriv, 'Type': 'StoreKey'});
    }
    if (_passwordKeyId != null && _password != null) {
      keys.add({'Id': _passwordKeyId, 'Key': _password, 'Type': 'Password'});
    }
    return keys;
  }

  /// Build the `oldKeys` list for a device-share reshare ceremony.
  ///
  /// Pure function — extracted from [_resharedDeviceShare] so it can be
  /// unit-tested without a live [LibwalletClient]. The wallet must
  /// carry a StoreKey row (we're replacing it); throws otherwise. The
  /// StoreKey entry is included only when [storeKeyPriv] is non-null,
  /// since that's the 64-byte private produced by StoreKey:create and
  /// is what libwallet's opener expects — the wallet's stored
  /// `WalletKey.key` is the X.509 public, which would trip the length
  /// check. On a recovery device that never held the private, omit
  /// the entry; Password + RemoteKey still satisfies T+1 for a 2-of-3
  /// wallet, and `reshareNew` mints the replacement StoreKey.
  @visibleForTesting
  /// Build the OLD-committee key descriptors for a reshare. Include only the
  /// shares the caller can actually authorize with (any two of three):
  /// - device-share recovery: pass [password] + null [storeKeyPriv] →
  ///   `[Password, RemoteKey]`.
  /// - password reset via 2FA: pass [storeKeyPriv] + null [password] →
  ///   `[StoreKey, RemoteKey]`.
  static List<KeyDescription> buildReshareOldKeys({
    required Wallet wallet,
    String? password,
    required String? storeKeyPriv,
    String? freshRemoteKeyResource,
  }) {
    final oldStoreKey = wallet.keys.firstWhere(
      (k) => k.type == 'StoreKey',
      orElse: () => throw StateError('Wallet has no StoreKey share'),
    );
    WalletKey? oldPasswordKey;
    WalletKey? oldRemoteKey;
    for (final k in wallet.keys) {
      if (k.type == 'Password') oldPasswordKey = k;
      if (k.type == 'RemoteKey') oldRemoteKey = k;
    }
    // A supplied password must correspond to a Password share on the wallet —
    // preserve the original contract. (When [password] is null the Password
    // share is intentionally omitted from the committee.)
    if (password != null && oldPasswordKey == null) {
      throw StateError('Wallet has no Password share');
    }

    // Per libwallet 0.4.37 device_share.md: the stored
    // `WalletKey.key` for the RemoteKey share is the original keygen
    // session id which the server marked `done`. Reshare against it
    // produces `invalid status for wallet sign session: done`.
    // Callers in the cross-device recovery flow must run
    // RemoteKey:reshare + :validate first and pass the fresh
    // `RemoteKeyValidation.remoteKey` here.
    final remoteKeyForReshare = freshRemoteKeyResource ?? oldRemoteKey?.key;

    return <KeyDescription>[
      if (storeKeyPriv != null)
        KeyDescription(
          type: 'StoreKey',
          key: storeKeyPriv,
          id: oldStoreKey.id,
        ),
      if (oldRemoteKey != null && remoteKeyForReshare != null)
        KeyDescription(
          type: 'RemoteKey',
          key: remoteKeyForReshare,
          id: oldRemoteKey.id,
        ),
      if (password != null && oldPasswordKey != null)
        KeyDescription(
          type: 'Password',
          key: password,
          id: oldPasswordKey.id,
        ),
    ];
  }

  /// Auto-rotate the device share on a wallet that exists locally but
  /// has no SecureKeystore entry for its StoreKey private. Per
  /// libwallet's device-share docs
  /// (https://github.com/KarpelesLab/libwallet/blob/master/dart/doc/device_share.md),
  /// the wallet has T+1 shares available on a fresh device (RemoteKey
  /// via the authenticated WalletSign session + Password from the user)
  /// — enough to authorize the reshare ceremony. Mints a new StoreKey,
  /// reshares to swap it in, and persists the private half locally.
  ///
  /// Caller is responsible for using the returned private key (set
  /// `_storeKeyPriv = …`). Throws on any failure; surrounding code
  /// should surface a clear error.
  Future<String> _resharedDeviceShare({
    required LibwalletClient client,
    required Wallet wallet,
    required String password,
    String? freshRemoteKeyResource,
  }) async {
    final newStorePair = await client.storeKeys.create();
    final reshareOld = buildReshareOldKeys(
      wallet: wallet,
      password: password,
      storeKeyPriv: _storeKeyPriv,
      freshRemoteKeyResource: freshRemoteKeyResource,
    );
    WalletKey? oldRemoteKey;
    for (final k in wallet.keys) {
      if (k.type == 'RemoteKey') {
        oldRemoteKey = k;
        break;
      }
    }
    final remoteKeyForReshare = freshRemoteKeyResource ?? oldRemoteKey?.key;
    final reshareNew = <KeyDescription>[
      KeyDescription.storeKey(newStorePair.publicKey),
      if (oldRemoteKey != null && remoteKeyForReshare != null)
        KeyDescription(type: 'RemoteKey', key: remoteKeyForReshare),
      KeyDescription.password(password),
    ];
    Wallet? afterReshare;
    await for (final ev in client.wallets.reshare(
      wallet.id,
      oldKeys: reshareOld,
      newKeys: reshareNew,
    )) {
      if (ev is Complete<Wallet>) afterReshare = ev.value;
    }
    if (afterReshare == null) {
      throw StateError('Device-share reshare did not return a wallet');
    }
    final freshKeyIds = _extractKeyIdsByType(afterReshare);
    final freshStoreKeyId = freshKeyIds['StoreKey'];
    if (freshStoreKeyId == null) {
      throw StateError('Post-reshare wallet is missing its StoreKey');
    }

    // Persist new metadata + private key. Reshare didn't touch the
    // RemoteKey or Password slot, so their IDs stay the same (we
    // only refresh StoreKey-related state).
    _storeKeyId = freshStoreKeyId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsStorePub, newStorePair.publicKey);
    await prefs.setString(_prefsStoreKeyId, freshStoreKeyId);
    await _keystore.writeDeviceShare(
      walletId: _walletId!,
      value: newStorePair.privateKey,
      password: password,
    );
    return newStorePair.privateKey;
  }

  Future<void> _persist({
    String? storeKeyPublic,
    bool osKeystoreCopy = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsWalletId, _walletId!);
    await prefs.setString(_prefsAccountId, _accountId!);
    await prefs.setString(_prefsAddress, _publicKey!);
    await prefs.setString(_prefsName, _walletName!);
    // A D5 (password-only) wallet has no StoreKey — clear any stale entries
    // so tryRestore sees null and routes signing through the sheet.
    if (storeKeyPublic != null) {
      await prefs.setString(_prefsStorePub, storeKeyPublic);
    } else {
      await prefs.remove(_prefsStorePub);
    }
    if (_storeKeyId != null) {
      await prefs.setString(_prefsStoreKeyId, _storeKeyId!);
    } else {
      await prefs.remove(_prefsStoreKeyId);
    }
    if (_remoteKeyId != null) {
      await prefs.setString(_prefsRemoteKeyId, _remoteKeyId!);
    }
    if (_passwordKeyId != null) {
      await prefs.setString(_prefsPasswordKeyId, _passwordKeyId!);
    }
    // The device-share private key — the only true secret on this side —
    // goes through SecureKeystore, never plaintext SharedPreferences. A D5
    // wallet has no device share, so there's nothing to write.
    if (_storeKeyPriv != null) {
      await _keystore.writeDeviceShare(
        walletId: _walletId!,
        value: _storeKeyPriv!,
        password: _password!,
        osKeystoreCopy: osKeystoreCopy,
      );
    }
    // If we somehow still have a legacy plaintext entry, scrub it.
    await prefs.remove(_prefsStorePriv);
  }

  Map<String, String> _extractKeyIdsByType(Wallet w) {
    final map = <String, String>{};
    for (final k in w.keys) {
      map[k.type] = k.id;
    }
    return map;
  }
}
