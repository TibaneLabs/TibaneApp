import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:libwallet/libwallet.dart'
    show Account, AddressFormat, Wallet, SigningKey;
import 'package:shared_preferences/shared_preferences.dart';

import '../catcard/catcard_wallet_backend.dart';
import 'libwallet_backend.dart';
import 'mwa_wallet_backend.dart';
import 'unified_account.dart';
import 'wallet_group_store.dart';
import 'wallet_export_format.dart' show isNormalMnemonicWallet;

/// The single source of truth for the account list (Atonline-parity: the
/// `AccountCubit` + `CurrentAccountCubit` role, as a `ChangeNotifier`).
///
/// Every consumer — the account switcher, the management screens, the
/// WalletConnect bridge, and `WalletService`'s current-account model — reads
/// the account list from HERE rather than calling `client.accounts.list()`
/// itself, so the phantom-account filter ([isUsableAccount]) lives in exactly
/// one place and the data can never diverge between surfaces.
///
/// Owns: the filtered raw [Account] list + [walletsById], the derived
/// [UnifiedAccount] list, the [current] account, and the switch mechanics
/// (network-matching + libwallet wallet/account switch + persistence).
///
/// Does NOT own backend-kind selection or balances — those stay in
/// [WalletService], which drives [refresh]/[setCurrent] at the right moments
/// and reconciles kind + balances afterwards.
class AccountsService extends ChangeNotifier {
  AccountsService(this._libwallet, this._mwa, {CatCardWalletBackend? catcard})
    : _catcard = catcard;

  final LibwalletBackend _libwallet;
  final MwaWalletBackend _mwa;
  final CatCardWalletBackend? _catcard;

  static const _prefsCurrentAccountId = 'current_account_id';
  static const _prefsAccountPreferredChains = 'account_preferred_chains';
  static const _prefsAttachedWalletParents = 'attached_wallet_parents_v1';
  // Wallet ids whose default accounts have been ensured. Additive-only; gates
  // the [refresh] default-account backfill so it runs at most once per wallet.
  static const _prefsDefaultsEnsured = 'wallet_defaults_ensured_v2';

  // Raw libwallet accounts AFTER filtering out phantoms — the authoritative
  // list the management screens render. Built once per [refresh].
  List<Account> _rawAccounts = const [];
  Map<String, Wallet> _walletsById = const {};
  Map<String, String> _attachedWalletParents = const {};
  Map<String, String> _walletGroups = const {};
  Map<String, String> get walletGroups => Map.unmodifiable(_walletGroups);

  // Derived unified list (in-app accounts across all wallets + the connected
  // MWA account) and the current selection.
  List<UnifiedAccount> _accounts = const [];
  UnifiedAccount? _current;
  final Map<String, String> _bitcoinAddressCache = {};

  /// Filtered raw accounts (no phantoms). Use for wallet-management surfaces
  /// that need libwallet [Account] fields (path/index/etc.).
  List<Account> get rawAccounts => _rawAccounts;

  /// Wallets keyed by id, as of the last [refresh].
  Map<String, Wallet> get walletsById => _walletsById;

  /// Technical MPC wallets that should appear as additional accounts inside a
  /// user-selected logical wallet: child wallet id -> parent wallet id.
  Map<String, String> get attachedWalletParents => _attachedWalletParents;

  /// The unified account list (in-app + MWA). Empty until the first [refresh].
  List<UnifiedAccount> get accounts => _accounts;

  /// The account that signs right now, as a [UnifiedAccount]; null when none
  /// is resolved yet.
  UnifiedAccount? get current => _current;

  /// Filtered raw accounts for a single wallet.
  List<Account> rawAccountsForWallet(String walletId) =>
      _rawAccounts.where((a) => a.wallet == walletId).toList();

  /// Rebuild the account list from libwallet (`accounts.list()` across all
  /// wallets) + the connected MWA account, dropping phantom accounts, and
  /// resolve [current]. [preferMwa] mirrors WalletService's active backend so
  /// the resolved current matches the signer. Best-effort.
  Future<void> refresh({
    required bool preferMwa,
    bool preferCatCard = false,
  }) async {
    try {
      final client = await _libwallet.ensureClient();
      final prefs = await SharedPreferences.getInstance();
      _walletGroups = await WalletGroupStore.read();
      final wallets = {for (final w in await client.wallets.list()) w.id: w};
      final storedParents = _decodeStringMap(
        prefs.getString(_prefsAttachedWalletParents),
      );
      final attachedParents = <String, String>{
        for (final entry in storedParents.entries)
          if (wallets.containsKey(entry.key) &&
              wallets.containsKey(entry.value))
            entry.key: entry.value,
      };
      if (!mapEquals(storedParents, attachedParents)) {
        await prefs.setString(
          _prefsAttachedWalletParents,
          jsonEncode(attachedParents),
        );
      }
      // Bootstrap default accounts at most once per wallet. Gating on a
      // persisted set (plus verify-before-create in the backend) stops a
      // transiently-partial accounts.list() from minting duplicate default
      // accounts on this hot read path. New wallets already get their defaults
      // at creation time, so this is only a backfill for older/edge wallets;
      // existing wallets auto-flag on the first refresh (defaults present).
      final alreadyEnsured =
          (prefs.getStringList(_prefsDefaultsEnsured) ?? const <String>[])
              .toSet();
      final ensure = await _libwallet.ensureDefaultAccountsForWallets(
        accounts: await client.accounts.list(),
        walletsById: wallets,
        alreadyEnsured: alreadyEnsured,
        accountOnlyWalletIds: attachedParents.keys.toSet(),
      );
      final rawList = ensure.accounts;
      final ensuredNow = alreadyEnsured.union(ensure.ensuredWalletIds);
      if (ensuredNow.length != alreadyEnsured.length) {
        await prefs.setStringList(
          _prefsDefaultsEnsured,
          ensuredNow.toList(growable: false),
        );
      }
      // Filter phantom accounts only (curve/type mismatch, non-0x EVM address,
      // or "N/A") — determined purely from the list() data, so this never hides
      // a real wallet.
      //
      // We deliberately do NOT probe `wallets.get()` to hide "unloadable"
      // wallets: libwallet's get() can flakily return 404 "file does not exist"
      // for VALID wallets, which would HIDE a real, working wallet (looks
      // deleted). Letting a switch to a genuinely-broken wallet fail with an
      // error is far safer than hiding a real one. (Removed the
      // unloadable-wallet probe that was dropping real wallets — see git
      // history / the BTL7hA incident.)
      final filtered = rawList
          .where((a) => isUsableAccount(a, wallets[a.wallet]))
          .toList();

      final dropped = rawList.length - filtered.length;
      if (dropped > 0) {
        debugPrint('[accounts] dropped $dropped phantom account(s)');
      }
      // Observability for the isUsableAccount(wallet == null) filter: log any
      // account hidden because its parent wallet is absent from wallets.list(),
      // so a real-wallet regression stays diagnosable (see the BTL7hA incident).
      final orphaned = rawList
          .where((a) => wallets[a.wallet] == null)
          .map((a) => a.id)
          .toList();
      if (orphaned.isNotEmpty) {
        debugPrint(
          '[accounts] hid ${orphaned.length} account(s) with no parent '
          'wallet: $orphaned',
        );
      }
      _rawAccounts = filtered;
      _walletsById = wallets;
      _attachedWalletParents = attachedParents;
      final bitcoinFamily = await _resolveBitcoinFamily(filtered, wallets);

      final preferredChains = _decodePreferredChains(
        prefs.getString(_prefsAccountPreferredChains),
      );
      final mwaAddr = _mwa.isConnected ? _mwa.publicKey : null;
      final catAddr = (_catcard?.isConnected ?? false)
          ? _catcard!.publicKey
          : null;
      _accounts = buildUnifiedAccounts(
        inappAccounts: filtered,
        walletsById: wallets,
        mwaAddress: mwaAddr,
        catCardAddress: catAddr,
        currentAccountId: _libwallet.accountId,
        currentNetworkType: _libwallet.currentNetwork?.type,
        currentNetworkChainId: _libwallet.currentNetwork?.chainId,
        currentAddress: _libwallet.publicKey,
        bitcoinAddressesByContextId: bitcoinFamily.addressesByContextId,
        bitcoinNetworkContexts: bitcoinFamily.contexts,
        preferredChainsByAccountId: preferredChains,
        additionalWalletIds: attachedParents.keys.toSet(),
      );
      _current = _resolveCurrent(
        _accounts,
        prefs.getString(_prefsCurrentAccountId),
        preferMwa: preferMwa,
        preferCatCard: preferCatCard,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('AccountsService.refresh failed: $e');
    }
  }

  /// Resolve which unified account is current — the persisted [savedId] is
  /// authoritative (encodes in-app vs MWA); see [resolveCurrentAccount].
  UnifiedAccount? _resolveCurrent(
    List<UnifiedAccount> accounts,
    String? savedId, {
    required bool preferMwa,
    bool preferCatCard = false,
  }) => resolveCurrentAccount(
    accounts: accounts,
    savedId: savedId,
    preferMwa: preferMwa,
    preferCatCard: preferCatCard,
    activeInAppAccountId: _libwallet.accountId,
    activeNetworkType: _libwallet.currentNetwork?.type,
    activeNetworkChainId: _libwallet.currentNetwork?.chainId,
  );

  Future<_BitcoinFamilyResolution> _resolveBitcoinFamily(
    List<Account> accounts,
    Map<String, Wallet> walletsById,
  ) async {
    final candidates = accounts.where((account) {
      final wallet = walletsById[account.wallet];
      return account.type == 'bitcoin' &&
          wallet?.curve == 'secp256k1' &&
          (wallet!.keys.length != 1 || isNormalMnemonicWallet(wallet)) &&
          !_attachedWalletParents.containsKey(account.wallet);
    }).toList();
    if (candidates.isEmpty) return const _BitcoinFamilyResolution();

    List<BitcoinNetworkContext> contexts = const [];
    try {
      final networks = await _libwallet.listNetworks();
      contexts = bitcoinContextsFromNetworks(networks);
    } catch (e) {
      debugPrint('AccountsService: could not list Bitcoin-family networks: $e');
      return const _BitcoinFamilyResolution();
    }
    if (contexts.isEmpty) return const _BitcoinFamilyResolution();

    final client = await _libwallet.ensureClient();
    final addresses = <String, String>{};
    for (final context in contexts) {
      final networkId = context.networkId;
      if (networkId == null || networkId.isEmpty) continue;
      for (final account in candidates) {
        final displayId = bitcoinContextId(context.chain, account.id);
        final cacheKey = '$networkId:${account.id}';
        final cached = _bitcoinAddressCache[cacheKey];
        if (cached != null && cached.isNotEmpty) {
          addresses[displayId] = cached;
          continue;
        }
        // Retry once: a single transient addressFormats failure would
        // otherwise leave this coin's context address-less until a later
        // refresh. libwallet 0.5.1 resolves the explicit network without
        // mutating whichever account/network the user currently has selected.
        String? address;
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final formats = await client.accounts.addressFormats(
              account.id,
              network: networkId,
            );
            address = _pickDefaultBitcoinFamilyAddress(formats.formats);
            if (address != null && address.isNotEmpty) break;
          } catch (e) {
            debugPrint(
              'AccountsService: could not resolve ${context.label} address '
              'for ${account.id} (attempt ${attempt + 1}): $e',
            );
          }
        }
        if (address != null && address.isNotEmpty) {
          addresses[displayId] = address;
          _bitcoinAddressCache[cacheKey] = address;
        }
      }
    }
    return _BitcoinFamilyResolution(
      contexts: contexts,
      addressesByContextId: addresses,
    );
  }

  /// Make [acct] the current account: for an in-app account, switch the
  /// network to one matching its chain (caller-picked [networkId], else the
  /// first compatible one) BEFORE switching libwallet's wallet/account so the
  /// address resolves correctly; persist the choice; update [current].
  ///
  /// Returns false on an in-app switch failure. Does NOT touch backend kind or
  /// balances — [WalletService.setCurrentAccount] wraps this with that.
  Future<bool> setCurrent(UnifiedAccount acct, {String? networkId}) async {
    if (acct.isInApp) {
      // Ensure a network matching the account's chain is active BEFORE
      // resolving the account — libwallet resolves an account's address for
      // the current network, so a chain mismatch yields "N/A".
      final cur = _libwallet.currentNetwork;
      final targetNetworkId = networkId ?? acct.networkId;
      if (targetNetworkId != null) {
        await _libwallet.setCurrentNetwork(targetNetworkId);
      } else if (cur == null ||
          !accountMatchesNetwork(acct, cur.type, networkChainId: cur.chainId)) {
        // Compare on the account's specific chain, not just NetworkType: two
        // bitcoin-family coins share NetworkType.bitcoin, so a type-only check
        // would treat a BTC→LTC switch as a no-op and leave the wrong network
        // active.
        try {
          final compatible = networksForAccount(
            acct,
            await _libwallet.listNetworks(),
          );
          if (compatible.isNotEmpty) {
            await _libwallet.setCurrentNetwork(compatible.first.id);
          }
        } catch (e) {
          debugPrint(
            'AccountsService.setCurrent: network auto-pick failed: $e',
          );
        }
      }
      final targetWallet = acct.walletId;
      if (targetWallet != null && targetWallet != _libwallet.walletId) {
        final r = await _libwallet.switchWallet(targetWallet);
        if (r != SwitchResult.ok) {
          debugPrint('AccountsService.setCurrent: switchWallet failed ($r)');
          return false;
        }
      }
      final targetAccount = acct.accountId;
      if (targetAccount != null && targetAccount != _libwallet.accountId) {
        if (!await _libwallet.switchAccount(targetAccount)) {
          debugPrint(
            'AccountsService.setCurrent: switchAccount failed: '
            '${_libwallet.error}',
          );
          return false;
        }
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsCurrentAccountId, acct.id);
    _current = acct;
    notifyListeners();
    return true;
  }

  /// Derive a new account on [walletId] (D10 add-account) and return it, or
  /// null on failure ([type] must be curve-compatible — constrained in the UI
  /// via [allowedAccountTypesForCurve]). The caller refreshes + switches.
  Future<Account?> createAccount({
    required String walletId,
    required String name,
    required String type,
    String? preferredChain,
    List<SigningKey>? keys,
  }) async {
    final account = await _libwallet.createAccount(
      walletId: walletId,
      name: name,
      type: type,
      keys: keys,
    );
    if (account != null && preferredChain != null) {
      await _setPreferredChain(account.id, preferredChain);
    }
    return account;
  }

  /// Attach a newly-created/imported technical wallet to the logical wallet
  /// selected by the user.
  Future<void> attachWalletAccount({
    required String childWalletId,
    required String parentWalletId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final parents = Map<String, String>.of(
      _decodeStringMap(prefs.getString(_prefsAttachedWalletParents)),
    );
    parents[childWalletId] = parentWalletId;
    await prefs.setString(_prefsAttachedWalletParents, jsonEncode(parents));
    _attachedWalletParents = parents;
  }

  Future<void> detachWalletAccount(String childWalletId) async {
    final prefs = await SharedPreferences.getInstance();
    final parents = Map<String, String>.of(
      _decodeStringMap(prefs.getString(_prefsAttachedWalletParents)),
    )..remove(childWalletId);
    await prefs.setString(_prefsAttachedWalletParents, jsonEncode(parents));
    _attachedWalletParents = parents;
  }

  /// Clear every wallet/account pointer owned by this service after a
  /// user-confirmed device reset. General app preferences are intentionally
  /// left alone.
  Future<void> clearLocalWalletState() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in const [
      _prefsCurrentAccountId,
      _prefsAccountPreferredChains,
      _prefsAttachedWalletParents,
      _prefsDefaultsEnsured,
      WalletGroupStore.preferenceKey,
    ]) {
      await prefs.remove(key);
    }
    for (final key in prefs.getKeys().where(
      (k) => k.startsWith('libw_password_rotation_pending_'),
    )) {
      await prefs.remove(key);
    }
    _rawAccounts = const [];
    _walletsById = const {};
    _attachedWalletParents = const {};
    _walletGroups = const {};
    _accounts = const [];
    _current = null;
    _bitcoinAddressCache.clear();
    notifyListeners();
  }

  Future<void> _setPreferredChain(String accountId, String chain) async {
    final prefs = await SharedPreferences.getInstance();
    final chains = Map<String, String>.of(
      _decodePreferredChains(prefs.getString(_prefsAccountPreferredChains)),
    );
    chains[accountId] = chain;
    await prefs.setString(_prefsAccountPreferredChains, jsonEncode(chains));
  }

  static Map<String, String> _decodePreferredChains(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } catch (_) {
      return const {};
    }
  }

  static Map<String, String> _decodeStringMap(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } catch (_) {
      return const {};
    }
  }
}

class _BitcoinFamilyResolution {
  final List<BitcoinNetworkContext> contexts;
  final Map<String, String> addressesByContextId;

  const _BitcoinFamilyResolution({
    this.contexts = const [],
    this.addressesByContextId = const {},
  });
}

String? _pickDefaultBitcoinFamilyAddress(Iterable<AddressFormat> formats) {
  String? firstUsable;
  for (final format in formats) {
    final address = (format.address as String?)?.trim();
    if (!isBitcoinFamilyAddress(address)) continue;
    firstUsable ??= address;
    if (format.isDefault == true) return address;
  }
  return firstUsable;
}
