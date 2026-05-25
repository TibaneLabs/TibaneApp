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
import 'secure_keystore.dart';
import 'wallet_backend.dart';

/// Minimal token result shape returned by
/// [LibwalletBackend.searchCuratedTokens] — symbol/name/mint/image,
/// suitable for rendering directly in a list or wrapping into a
/// [FavoriteToken] when navigating into a downstream screen.
class TokenSearchResult {
  final String mint;
  final String? name;
  final String? symbol;
  final String? imageUrl;

  const TokenSearchResult({
    required this.mint,
    this.name,
    this.symbol,
    this.imageUrl,
  });
}

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
  static const _prefsBiometricEnabled = 'libw_biometric_enabled';
  static const _prefsNetworkPicked = 'libw_network_picked';

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

  /// True when the local SecureKeystore (or its password-encrypted
  /// fallback blob) holds the device-share private. False after a
  /// cross-device backup import, or any time the device share has
  /// gone missing — used by the unlock screen to route between the
  /// normal password prompt and the 2FA recovery flow.
  Future<bool> hasLocalDeviceShare() => _keystore.hasDeviceShare();

  /// Wallet handle on the libwallet backend; null until a wallet exists.
  String? get walletId => _walletId;

  /// IDs of the three TSS key shares (null until the wallet has been
  /// created and persisted). Exposed so the wallet-details screen can
  /// render each share with its protection mechanism.
  String? get storeKeyId => _storeKeyId;
  String? get remoteKeyId => _remoteKeyId;
  String? get passwordKeyId => _passwordKeyId;

  /// In-memory password while the wallet is unlocked, or null. Exposed
  /// only so the biometric-cache toggle can stash it; do not hold on to
  /// the returned string longer than necessary.
  String? get currentPassword => _password;

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
          final d = await client.tokens
              .discover(network: chainKey, address: mint);
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

  Future<LibwalletClient> _getClient() async {
    if (_client != null) return _client!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/libwallet');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    _client = LibwalletClient.initialize(dir.path);
    await _client!.info.ping();
    await _registerWalletInfo(_client!);
    _balanceSub ??= _client!.balanceChanges.listen((_) {
      balanceTick.value++;
    });
    // On Flutter+iOS the Go runtime's stderr is dropped, so libwallet's
    // internal logs only surface via this stream. Pipe them to
    // debugPrint so backfill / RPC / poller activity is visible when
    // diagnosing "empty tx list" type issues.
    _logSub ??= _client!.logs.listen((e) {
      debugPrint('[libwallet:${e.level}] ${e.message}');
    });
    return _client!;
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
  /// Exposed so components like the dApp browser can subscribe to
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
    debugPrint(
        'remoteKey verification started: length=${session.length}');
    return session;
  }

  /// Backwards-compatible alias retained while older call sites migrate.
  @Deprecated('use startVerification(identifier) which also handles phone numbers')
  Future<RemoteKeySession> startEmailVerification(String email) =>
      startVerification(email);

  /// Complete the verification step. Returns the `remoteKey` identifier to
  /// pass to [create].
  Future<String> verifyEmailCode({
    required String session,
    required String code,
  }) async {
    final client = await _getClient();
    final validation = await client.remoteKeys.validate(session: session, code: code);
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

      // Device share.
      final storePair = await client.storeKeys.create();
      final keys = [
        KeyDescription.storeKey(storePair.publicKey),
        KeyDescription.remoteKey(remoteKey),
        KeyDescription.password(password),
      ];

      final Map<String, Wallet> createdByCurve;
      if (curves.length > 1) {
        Map<String, Wallet>? both;
        await for (final ev in client.wallets.multiCreate(name: name, keys: keys)) {
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
            name: name, curve: curves.first, keys: keys)) {
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
      _storeKeyPriv = storePair.privateKey;
      _storeKeyId = walletKeyIds['StoreKey'];
      _remoteKeyId = walletKeyIds['RemoteKey'];
      _passwordKeyId = walletKeyIds['Password'];
      _password = password;

      await _persist(storeKeyPublic: storePair.publicKey);
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
        priv = await _keystore.readDeviceShare(password: password);
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
          await _keystore.writeDeviceShare(value: legacy, password: password);
          await prefs.remove(_prefsStorePriv);
          debugPrint('Migrated device share to SecureKeystore');
        }
      }
      if (priv == null) {
        // No local device share — the unlock UI is responsible for
        // routing the user through the 2FA recovery flow before
        // calling unlock again. We surface the absence as a typed
        // signal so the host can branch cleanly.
        _error = 'Device share not found on this device. '
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
      unawaited(_keystore.writeDeviceShare(value: priv, password: password));
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
          value: _storeKeyPriv!,
          password: newPassword,
        );
      }
      if (await isBiometricEnabled()) {
        await _keystore.writeBiometricPassword(newPassword);
      }
      if (_passwordKeyId != null) {
        await prefs.setString(_prefsPasswordKeyId, _passwordKeyId!);
      }
      notifyListeners();
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
      final validation =
          await client.remoteKeys.validate(session: session, code: code);
      if (validation.remoteKey.isNotEmpty &&
          validation.remoteKey != _remoteKeyId) {
        _remoteKeyId = validation.remoteKey;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsRemoteKeyId, _remoteKeyId!);
      }
      notifyListeners();
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
      final validation = await client.remoteKeys
          .validate(session: sessionToken, code: code);
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
        value: storePair.privateKey,
        password: _password!,
      );
      notifyListeners();
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
        _error = 'Switching to an account on a different wallet is not yet supported';
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

  /// Forget session secrets. Wallet metadata persists; user must unlock again
  /// before signing.
  void lock() {
    _storeKeyPriv = null;
    _password = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Biometric password cache
  // ------------------------------------------------------------------

  /// Whether the user has opted in to the biometric password cache. Read
  /// from SharedPreferences so the flag survives a process restart.
  Future<bool> isBiometricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsBiometricEnabled) ?? false;
  }

  /// True when the platform exposes a usable biometric-backed keystore.
  /// The Settings toggle should be hidden when this is false.
  Future<bool> isBiometricSupported() => _keystore.isBiometricAvailable();

  /// Enable the biometric cache: store [password] behind a biometric gate
  /// so future signing flows can unlock with FaceID / Touch ID instead
  /// of asking for the password. Requires the wallet to currently be
  /// unlocked (i.e. [isUnlocked] true with this password).
  Future<bool> enableBiometricUnlock(String password) async {
    try {
      await _keystore.writeBiometricPassword(password);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsBiometricEnabled, true);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('enableBiometricUnlock failed: $e');
      return false;
    }
  }

  /// Disable the biometric cache and wipe the stored password.
  Future<void> disableBiometricUnlock() async {
    await _keystore.deleteBiometricPassword();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsBiometricEnabled, false);
    notifyListeners();
  }

  /// Prompt FaceID / Touch ID, read the cached password, and run [unlock]
  /// with it. Returns false if biometric isn't enabled, the user cancelled,
  /// or the underlying password unlock failed.
  Future<bool> unlockWithBiometric() async {
    if (!await isBiometricEnabled()) return false;
    final cached = await _keystore.readBiometricPassword();
    if (cached == null) return false;
    return unlock(cached);
  }

  @override
  Future<void> disconnect() async {
    try {
      if (_walletId != null) {
        final client = await _getClient();
        await client.wallets.delete(_walletId!);
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
      _prefsBiometricEnabled,
      _prefsNetworkPicked,
    ]) {
      await prefs.remove(key);
    }
    await _keystore.deleteDeviceShare();
    await _keystore.deleteBiometricPassword();
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
  Future<List<Uint8List?>> signTransactions(List<Uint8List> transactions) async {
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
  Future<List<String?>> signAndSendTransactions(List<Uint8List> transactions) async {
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

    bool isMine(Transaction t) => t.from == forAddress || t.to == forAddress;
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
        results.add(TokenSearchResult(
          mint: t.address,
          name: t.name,
          symbol: t.symbol,
          imageUrl: t.logoUri.isEmpty ? null : t.logoUri,
        ));
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
    debugPrint('[txhist] kickHistoryBackfill: calling accounts.setCurrent($accountId)');
    try {
      final client = await _getClient();
      await client.accounts.setCurrent(accountId);
      debugPrint('[txhist] kickHistoryBackfill: setCurrent returned — backfill triggered');
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
          throw const FormatException('Each entry needs string filename and data');
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
        throw StateError(
          'Backup contains no Solana (ed25519) wallet',
        );
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
    final tx = UnsignedTransaction(
      type: 'transfer',
      to: to,
      from: _accountId,
      amount: amount,
      asset: asset,
      priorityLevel: 'medium',
    );
    return client.transactions.simulate(tx);
  }

  /// Send SOL or an SPL token. Returns the broadcast transaction.
  Future<Transaction> send({
    required String to,
    required Amount amount,
    String? asset,
  }) async {
    final client = await _getClient();
    final keys = _signingKeys()
        .map((k) => SigningKey(
              id: k['Id'] as String,
              key: k['Key'] as String,
              type: k['Type'] as String?,
            ))
        .toList();
    final tx = UnsignedTransaction(
      type: 'transfer',
      to: to,
      from: _accountId,
      amount: amount,
      asset: asset,
      priorityLevel: 'medium',
    );
    return client.transactions.signAndSendSimple(tx, keys: keys);
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
    // Find the existing shares we'll reference in oldKeys.
    final oldStoreKey = wallet.keys.firstWhere(
      (k) => k.type == 'StoreKey',
      orElse: () => throw StateError('Wallet has no StoreKey share'),
    );
    final oldPasswordKey = wallet.keys.firstWhere(
      (k) => k.type == 'Password',
      orElse: () => throw StateError('Wallet has no Password share'),
    );
    WalletKey? oldRemoteKey;
    for (final k in wallet.keys) {
      if (k.type == 'RemoteKey') {
        oldRemoteKey = k;
        break;
      }
    }

    // Per libwallet 0.4.37 device_share.md: the stored
    // `WalletKey.key` for the RemoteKey share is the original keygen
    // session id which the server marked `done`. Reshare against it
    // produces `invalid status for wallet sign session: done`.
    // Callers in the cross-device recovery flow must run
    // RemoteKey:reshare + :validate first and pass the fresh
    // `RemoteKeyValidation.remoteKey` here. The fresh id replaces
    // the stored one on BOTH the old and new RemoteKey
    // KeyDescriptions.
    final remoteKeyForReshare =
        freshRemoteKeyResource ?? oldRemoteKey?.key;

    final newStorePair = await client.storeKeys.create();
    final reshareOld = <KeyDescription>[
      KeyDescription(
        type: 'StoreKey',
        key: oldStoreKey.key,
        id: oldStoreKey.id,
      ),
      if (oldRemoteKey != null && remoteKeyForReshare != null)
        KeyDescription(
          type: 'RemoteKey',
          key: remoteKeyForReshare,
          id: oldRemoteKey.id,
        ),
      KeyDescription(
        type: 'Password',
        key: password,
        id: oldPasswordKey.id,
      ),
    ];
    final reshareNew = <KeyDescription>[
      KeyDescription.storeKey(newStorePair.publicKey),
      if (oldRemoteKey != null && remoteKeyForReshare != null)
        KeyDescription(
          type: 'RemoteKey',
          key: remoteKeyForReshare,
        ),
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
      value: newStorePair.privateKey,
      password: password,
    );
    return newStorePair.privateKey;
  }

  Future<void> _persist({required String storeKeyPublic}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsWalletId, _walletId!);
    await prefs.setString(_prefsAccountId, _accountId!);
    await prefs.setString(_prefsAddress, _publicKey!);
    await prefs.setString(_prefsName, _walletName!);
    await prefs.setString(_prefsStorePub, storeKeyPublic);
    await prefs.setString(_prefsStoreKeyId, _storeKeyId!);
    if (_remoteKeyId != null) {
      await prefs.setString(_prefsRemoteKeyId, _remoteKeyId!);
    }
    if (_passwordKeyId != null) {
      await prefs.setString(_prefsPasswordKeyId, _passwordKeyId!);
    }
    // The device-share private key — the only true secret on this side —
    // goes through SecureKeystore, never plaintext SharedPreferences.
    await _keystore.writeDeviceShare(
      value: _storeKeyPriv!,
      password: _password!,
    );
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

