import 'package:libwallet/libwallet.dart'
    show Account, Network, NetworkType, Wallet;

/// Which backend owns / signs for an account.
enum AccountBackend { inapp, mwa }

/// One app-level account spanning both backends (in-app MPC + external MWA/Seed
/// Vault) and every chain — the unit the account switcher and `WalletService`'s
/// current-account model are keyed on (Atonline-parity §4.2, D1).
///
/// Assembled by [buildUnifiedAccounts]; identity is [id].
class UnifiedAccount {
  final AccountBackend backend;

  /// libwallet chain/network type: `solana`, `ethereum`, `bitcoin`, … — selects
  /// the network + asset/RPC/send path. MWA (Seed Vault) is always `solana`.
  final String chain;

  /// Chain-native address.
  final String address;

  /// Display label: in-app `"<account name> — <wallet name>"`; MWA
  /// `"External (Seed Vault)"`.
  final String label;

  /// in-app only — libwallet ids needed to sign and to fetch assets.
  final String? walletId;
  final String? accountId;
  final String? curve;

  const UnifiedAccount({
    required this.backend,
    required this.chain,
    required this.address,
    required this.label,
    this.walletId,
    this.accountId,
    this.curve,
  });

  bool get isInApp => backend == AccountBackend.inapp;
  bool get isMwa => backend == AccountBackend.mwa;
  bool get isSolana => chain == 'solana';

  /// Stable identity: in-app → `accountId`; MWA → `"mwa:<address>"`.
  String get id => isInApp ? accountId! : 'mwa:$address';

  @override
  String toString() => 'UnifiedAccount($id, $backend, $chain, "$label")';
}

/// Label shown for the external Seed Vault account.
const String mwaAccountLabel = 'External (Seed Vault)';

/// libwallet backend bug sentinel: an account whose address it couldn't
/// resolve comes back with `address == "N/A"` (or empty). The libwallet team
/// confirmed such accounts shouldn't exist — they're a server-side bug — so we
/// treat them as unusable and never display, select, or switch to them.
bool isUsableAccountAddress(String? address) {
  final a = address?.trim() ?? '';
  return a.isNotEmpty && a != 'N/A';
}

/// The SINGLE predicate for "is this a real, transactable account" — applied
/// wherever raw `client.accounts.list()` results reach the UI or the
/// current-account model so phantom accounts can never appear anywhere.
///
/// libwallet can emit phantom accounts (typically from a restore) whose type
/// is incompatible with the parent wallet's curve — e.g. an `ethereum` account
/// under an `ed25519`/Solana wallet. `list()` returns these with the wallet's
/// native (base58) address as a fallback, but they can't derive a real EVM
/// address, so any real resolution gives `"N/A"`. We reject an account when:
///
/// - its [address] is empty / `"N/A"` ([isUsableAccountAddress]); or
/// - it is `ethereum`-typed but the address isn't `0x…` hex (a base58 address
///   means a fallback for an account that can't produce a real EVM address); or
/// - its `type` isn't allowed for the parent wallet's curve
///   ([allowedAccountTypesForCurve]) — the principled, network-independent
///   check. [wallet] null (unknown) → the curve check is skipped, the address
///   and `0x` checks still apply.
bool isUsableAccount(Account account, Wallet? wallet) {
  if (!isUsableAccountAddress(account.address)) return false;
  if (account.type == 'ethereum' && !account.address.startsWith('0x')) {
    return false;
  }
  final curve = wallet?.curve;
  if (curve != null &&
      !allowedAccountTypesForCurve(curve).contains(account.type)) {
    return false;
  }
  return true;
}

/// Pure builder for the unified account list (D1).
///
/// - [inappAccounts] — `client.accounts.list()` across all in-app wallets.
/// - [walletsById] — supplies each account's wallet name + curve.
/// - [mwaAddress] — the connected MWA/Seed Vault pubkey, or null when not
///   connected (Seed Vault is Solana-only, so the MWA entry is always Solana).
///
/// In-app accounts come first (in the order given), the MWA account last. Pure
/// + top-level so it's unit-testable without a libwallet client (follows the
/// existing `pickNextActive` / `signing.dart` helper pattern).
List<UnifiedAccount> buildUnifiedAccounts({
  required List<Account> inappAccounts,
  required Map<String, Wallet> walletsById,
  String? mwaAddress,
}) {
  final out = <UnifiedAccount>[];
  for (final a in inappAccounts) {
    final w = walletsById[a.wallet];
    // Skip phantom accounts (curve/type mismatch, non-0x EVM address, or
    // "N/A" — see [isUsableAccount]); they can't be displayed or transacted on.
    if (!isUsableAccount(a, w)) continue;
    final walletName = w?.name ?? '';
    final label = walletName.isEmpty ? a.name : '${a.name} — $walletName';
    out.add(
      UnifiedAccount(
        backend: AccountBackend.inapp,
        chain: a.type,
        address: a.address,
        label: label,
        walletId: a.wallet,
        accountId: a.id,
        curve: w?.curve,
      ),
    );
  }
  if (mwaAddress != null && mwaAddress.isNotEmpty) {
    out.add(
      UnifiedAccount(
        backend: AccountBackend.mwa,
        chain: 'solana',
        address: mwaAddress,
        label: mwaAccountLabel,
      ),
    );
  }
  return out;
}

/// Pick the account to make current after [removedId] is removed: the first
/// account whose id isn't the removed one, or null if none remain. Mirrors
/// `pickNextActive` for the account-centric model.
UnifiedAccount? pickNextAccount(
  List<UnifiedAccount> accounts,
  String removedId,
) {
  for (final a in accounts) {
    if (a.id != removedId) return a;
  }
  return null;
}

/// Resolve which account should be current on restore. Returns the account
/// matching [savedId] when it's still present; otherwise falls back to the
/// first in-app account (e.g. the saved account was the MWA one but Seed Vault
/// isn't connected this launch), else the first account, else null.
UnifiedAccount? resolvePersistedAccount({
  required List<UnifiedAccount> accounts,
  required String? savedId,
}) {
  if (accounts.isEmpty) return null;
  if (savedId != null) {
    for (final a in accounts) {
      if (a.id == savedId) return a;
    }
  }
  for (final a in accounts) {
    if (a.backend == AccountBackend.inapp) return a;
  }
  return accounts.first;
}

/// Resolve the current account on startup (account-centric model). The
/// persisted [savedId] is **authoritative** — it encodes the user's last-active
/// account (in-app OR MWA), so it wins over the live backend signals. This is
/// what lets the app reopen on the right account even when a stale Seed Vault
/// pubkey is restored alongside an in-app wallet.
///
/// Order: (1) the account matching [savedId]; (2) when there's no saved id, the
/// account matching the live active backend — the MWA account if [preferMwa],
/// else the in-app account whose id is [activeInAppAccountId]; (3) the
/// persisted/first-in-app fallback ([resolvePersistedAccount]).
UnifiedAccount? resolveCurrentAccount({
  required List<UnifiedAccount> accounts,
  required String? savedId,
  required bool preferMwa,
  required String? activeInAppAccountId,
}) {
  if (savedId != null) {
    for (final a in accounts) {
      if (a.id == savedId) return a;
    }
  }
  if (preferMwa) {
    for (final a in accounts) {
      if (a.isMwa) return a;
    }
  } else {
    for (final a in accounts) {
      if (a.isInApp && a.accountId == activeInAppAccountId) return a;
    }
  }
  return resolvePersistedAccount(accounts: accounts, savedId: savedId);
}

/// Account `type`s that can be derived for a wallet of the given [curve].
/// libwallet derives the key from the curve, so a new account's type must match
/// it (ed25519 → solana; secp256k1 → ethereum/bitcoin) or the TSS layer derives
/// the wrong key type and crashes. Empty for an unknown/absent curve.
List<String> allowedAccountTypesForCurve(String? curve) {
  switch (curve) {
    case 'ed25519':
      return const ['solana'];
    case 'secp256k1':
      return const ['ethereum', 'bitcoin'];
    default:
      return const [];
  }
}

/// The in-app account whose wallet a new account should be added to: the
/// current account when it's in-app, else the first in-app account, else null
/// (e.g. only an MWA account is present — MWA can't derive new accounts).
UnifiedAccount? addAccountTarget(
  List<UnifiedAccount> accounts,
  UnifiedAccount? current,
) {
  if (current != null && current.isInApp) return current;
  for (final a in accounts) {
    if (a.isInApp) return a;
  }
  return null;
}

/// The first in-app account on [walletId], or null when none is surfaced — the
/// account a lockless "use this wallet" switch (wallet-details) targets.
UnifiedAccount? accountForWallet(
  List<UnifiedAccount> accounts,
  String walletId,
) {
  for (final a in accounts) {
    if (a.isInApp && a.walletId == walletId) return a;
  }
  return null;
}

/// The first in-app account in [accounts], or null (e.g. only an MWA account) —
/// the account the wallet-button "activate my existing wallet" flow switches to.
UnifiedAccount? firstInAppAccount(List<UnifiedAccount> accounts) {
  for (final a in accounts) {
    if (a.isInApp) return a;
  }
  return null;
}

/// Default name for the next account on a wallet: "Account N" (1-based on the
/// number of accounts the wallet already has).
String suggestAccountName(int existingCount) => 'Account ${existingCount + 1}';

/// The libwallet [NetworkType] an account of [chain] runs on. An account's
/// address only works while the current network matches this family — so
/// switching to a different-chain account needs a compatible network.
NetworkType networkTypeForChain(String chain) {
  switch (chain) {
    case 'ethereum':
      return NetworkType.evm;
    case 'bitcoin':
      return NetworkType.bitcoin;
    case 'solana':
    default:
      return NetworkType.solana;
  }
}

/// Networks compatible with [account] (same chain family) — the list offered
/// when switching to a different-chain account so the user picks which network
/// to connect on (e.g. an EVM account → Ethereum / Polygon / BSC / …).
List<Network> networksForAccount(UnifiedAccount account, List<Network> all) {
  final t = networkTypeForChain(account.chain);
  return all.where((n) => n.type == t).toList();
}

/// Whether [networkType] matches [account]'s chain — i.e. the account is
/// usable on that network without a network switch.
bool accountMatchesNetwork(UnifiedAccount account, NetworkType networkType) =>
    networkTypeForChain(account.chain) == networkType;

/// Whether Solana-only features (Staking, Incinerator — both are Solana
/// programs / SPL operations) should be offered for [current]. True when the
/// current account is Solana, or when there's no current account yet (Tibane is
/// Solana-first, so the tools stay visible until we know it's a non-Solana
/// account — the disconnected UI prompts connect on use).
bool solanaOnlyFeaturesEnabled(UnifiedAccount? current) =>
    current == null || current.isSolana;

/// Human label for a chain `type`.
String chainLabel(String chain) {
  switch (chain) {
    case 'solana':
      return 'Solana';
    case 'ethereum':
      return 'Ethereum';
    case 'bitcoin':
      return 'Bitcoin';
    default:
      return chain.isEmpty ? '' : chain[0].toUpperCase() + chain.substring(1);
  }
}
