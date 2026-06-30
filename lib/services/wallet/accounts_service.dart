import 'package:flutter/foundation.dart';
import 'package:libwallet/libwallet.dart'
    show Account, Wallet;
import 'package:shared_preferences/shared_preferences.dart';

import 'libwallet_backend.dart';
import 'mwa_wallet_backend.dart';
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

  // Raw libwallet accounts AFTER filtering out phantoms — the authoritative
  // list the management screens render. Built once per [refresh].
  List<Account> _rawAccounts = const [];
  Map<String, Wallet> _walletsById = const {};

  // Derived unified list (in-app accounts across all wallets + the connected
  // MWA account) and the current selection.
  List<UnifiedAccount> _accounts = const [];
  UnifiedAccount? _current;

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
      final rawList = await client.accounts.list();
      final wallets = {
        for (final w in await client.wallets.list()) w.id: w,
      };
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
      final filtered =
          rawList.where((a) => isUsableAccount(a, wallets[a.wallet])).toList();

      final dropped = rawList.length - filtered.length;
      if (dropped > 0) {
        debugPrint('[accounts] dropped $dropped phantom account(s)');
      }
      _rawAccounts = filtered;
      _walletsById = wallets;

      final mwaAddr = _mwa.isConnected ? _mwa.publicKey : null;
      _accounts = buildUnifiedAccounts(
        inappAccounts: filtered,
        walletsById: wallets,
        mwaAddress: mwaAddr,
      );
      final prefs = await SharedPreferences.getInstance();
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

  /// Resolve which unified account is current: first the one matching the
  /// active backend (preserves the old `_matchActiveAccount` semantics), then
  /// the persisted/first-in-app fallback.
  UnifiedAccount? _resolveCurrent(
    List<UnifiedAccount> accounts,
    String? savedId, {
    required bool preferMwa,
  }) {
    if (preferMwa) {
      for (final a in accounts) {
        if (a.isMwa) return a;
      }
    } else {
      final aid = _libwallet.accountId;
      for (final a in accounts) {
        if (a.isInApp && a.accountId == aid) return a;
      }
    }
    return resolvePersistedAccount(accounts: accounts, savedId: savedId);
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
      if (networkId != null) {
        await _libwallet.setCurrentNetwork(networkId);
      } else if (cur == null ||
          cur.type != networkTypeForChain(acct.chain)) {
        try {
          final compatible =
              networksForAccount(acct, await _libwallet.listNetworks());
          if (compatible.isNotEmpty) {
            await _libwallet.setCurrentNetwork(compatible.first.id);
          }
        } catch (e) {
          debugPrint('AccountsService.setCurrent: network auto-pick failed: $e');
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
  }) =>
      _libwallet.createAccount(walletId: walletId, name: name, type: type);
}
