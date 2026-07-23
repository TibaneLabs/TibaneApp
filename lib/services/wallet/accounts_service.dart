import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:libwallet/libwallet.dart' show Account, AddressFormat, Wallet;
import 'package:shared_preferences/shared_preferences.dart';

import 'libwallet_backend.dart';
import 'mwa_wallet_backend.dart';
import 'account_avatar_assets.dart';
import 'unified_account.dart';

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
  AccountsService(this._libwallet, this._mwa);

  final LibwalletBackend _libwallet;
  final MwaWalletBackend _mwa;

  static const _prefsCurrentAccountId = 'current_account_id';
  static const _prefsAccountPreferredChains = 'account_preferred_chains';
  static const _prefsAccountAvatarAssets = 'account_avatar_assets_v1';
  // Wallet ids whose default accounts have been ensured. Additive-only; gates
  // the [refresh] default-account backfill so it runs at most once per wallet.
  static const _prefsDefaultsEnsured = 'wallet_defaults_ensured_v1';

  // Raw libwallet accounts AFTER filtering out phantoms — the authoritative
  // list the management screens render. Built once per [refresh].
  List<Account> _rawAccounts = const [];
  Map<String, Wallet> _walletsById = const {};

  // Derived unified list (in-app accounts across all wallets + the connected
  // MWA account) and the current selection.
  List<UnifiedAccount> _accounts = const [];
  UnifiedAccount? _current;
  final Map<String, String> _bitcoinAddressCache = {};
  final math.Random _avatarRandom = math.Random();

  /// Filtered raw accounts (no phantoms). Use for wallet-management surfaces
  /// that need libwallet [Account] fields (path/index/etc.).
  List<Account> get rawAccounts => _rawAccounts;

  /// Wallets keyed by id, as of the last [refresh].
  Map<String, Wallet> get walletsById => _walletsById;

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
  Future<void> refresh({required bool preferMwa}) async {
    try {
      final client = await _libwallet.ensureClient();
      final prefs = await SharedPreferences.getInstance();
      final wallets = {for (final w in await client.wallets.list()) w.id: w};
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
      final bitcoinFamily = await _resolveBitcoinFamily(filtered, wallets);

      final preferredChains = _decodePreferredChains(
        prefs.getString(_prefsAccountPreferredChains),
      );
      final mwaAddr = _mwa.isConnected ? _mwa.publicKey : null;
      final baseAccounts = buildUnifiedAccounts(
        inappAccounts: filtered,
        walletsById: wallets,
        mwaAddress: mwaAddr,
        currentAccountId: _libwallet.accountId,
        currentNetworkType: _libwallet.currentNetwork?.type,
        currentNetworkChainId: _libwallet.currentNetwork?.chainId,
        currentAddress: _libwallet.publicKey,
        bitcoinAddressesByContextId: bitcoinFamily.addressesByContextId,
        bitcoinNetworkContexts: bitcoinFamily.contexts,
        preferredChainsByAccountId: preferredChains,
      );
      final avatarAssets = await _ensureAccountAvatarAssets(
        prefs,
        baseAccounts,
      );
      _accounts = buildUnifiedAccounts(
        inappAccounts: filtered,
        walletsById: wallets,
        mwaAddress: mwaAddr,
        currentAccountId: _libwallet.accountId,
        currentNetworkType: _libwallet.currentNetwork?.type,
        currentNetworkChainId: _libwallet.currentNetwork?.chainId,
        currentAddress: _libwallet.publicKey,
        bitcoinAddressesByContextId: bitcoinFamily.addressesByContextId,
        bitcoinNetworkContexts: bitcoinFamily.contexts,
        preferredChainsByAccountId: preferredChains,
        accountAvatarAssetsById: avatarAssets,
      );
      _current = _resolveCurrent(
        _accounts,
        prefs.getString(_prefsCurrentAccountId),
        preferMwa: preferMwa,
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
  }) => resolveCurrentAccount(
    accounts: accounts,
    savedId: savedId,
    preferMwa: preferMwa,
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
      return account.type == 'ethereum' && wallet?.curve == 'secp256k1';
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
    for (final account in candidates) {
      for (final context in contexts) {
        final networkId = context.networkId;
        if (networkId == null || networkId.isEmpty) continue;
        final displayId = bitcoinContextId(context.chain, account.id);
        final cacheKey = '$networkId:${account.id}';
        final cached = _bitcoinAddressCache[cacheKey];
        if (cached != null && cached.isNotEmpty) {
          addresses[displayId] = cached;
          continue;
        }
        try {
          final formats = await client.accounts.addressFormats(
            account.id,
            network: networkId,
          );
          final address = _pickDefaultBitcoinFamilyAddress(formats.formats);
          if (address != null && address.isNotEmpty) {
            addresses[displayId] = address;
            _bitcoinAddressCache[cacheKey] = address;
          }
        } catch (e) {
          debugPrint(
            'AccountsService: could not resolve ${context.label} address for '
            '${account.id}: $e',
          );
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
      } else if (cur == null || cur.type != networkTypeForChain(acct.chain)) {
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
    String? avatarAsset,
  }) async {
    final account = await _libwallet.createAccount(
      walletId: walletId,
      name: name,
      type: type,
    );
    if (account != null && preferredChain != null) {
      await _setPreferredChain(account.id, preferredChain);
    }
    if (account != null && avatarAsset != null) {
      final displayId = isBitcoinFamilyChain(preferredChain)
          ? bitcoinContextId(preferredChain!, account.id)
          : account.id;
      await _setAccountAvatarAsset(displayId, avatarAsset);
    }
    return account;
  }

  Future<String> suggestAvatarAsset({Set<String> usedAssets = const {}}) async {
    final prefs = await SharedPreferences.getInstance();
    final assignments = _decodeStringMap(
      prefs.getString(_prefsAccountAvatarAssets),
    );
    return pickAccountAvatarAsset(
      usedAssets: {...assignments.values, ...usedAssets},
      random: _avatarRandom,
    );
  }

  String? avatarAssetForRawAccount(String lwAccountId) {
    String? virtualFallback;
    for (final account in _accounts) {
      if (account.accountId != lwAccountId) continue;
      if (!account.isVirtual) {
        return account.avatarAsset;
      }
      virtualFallback ??= account.avatarAsset;
    }
    return virtualFallback;
  }

  Future<Map<String, String>> _ensureAccountAvatarAssets(
    SharedPreferences prefs,
    List<UnifiedAccount> accounts,
  ) async {
    final raw = _decodeStringMap(prefs.getString(_prefsAccountAvatarAssets));
    final next = ensureAccountAvatarAssignments(
      accountIds: accounts.where((a) => a.isInApp).map((a) => a.id),
      existingAssignments: raw,
      random: _avatarRandom,
    );
    if (!mapEquals(raw, next)) {
      await prefs.setString(_prefsAccountAvatarAssets, jsonEncode(next));
    }
    return next;
  }

  Future<void> _setAccountAvatarAsset(
    String unifiedAccountId,
    String asset,
  ) async {
    if (!kAccountAvatarAssets.contains(asset)) return;
    final prefs = await SharedPreferences.getInstance();
    final assignments = Map<String, String>.of(
      _decodeStringMap(prefs.getString(_prefsAccountAvatarAssets)),
    );
    assignments[unifiedAccountId] = asset;
    await prefs.setString(_prefsAccountAvatarAssets, jsonEncode(assignments));
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
