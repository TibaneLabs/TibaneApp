import 'package:libwallet/libwallet.dart' show Account, Wallet;

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

/// Default name for the next account on a wallet: "Account N" (1-based on the
/// number of accounts the wallet already has).
String suggestAccountName(int existingCount) => 'Account ${existingCount + 1}';

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
