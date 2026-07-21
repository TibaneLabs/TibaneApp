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

  /// Display label: in-app `"<wallet name> - <account name>"`; MWA
  /// `"External (Seed Vault)"`.
  final String label;

  /// User-facing wallet/account pieces used by grouped switcher UIs. [label]
  /// stays as the compact full label for older call sites.
  final String walletName;
  final String accountName;
  final int? accountIndex;

  /// in-app only — libwallet ids needed to sign and to fetch assets.
  final String? walletId;
  final String? accountId;
  final String? curve;
  final String? idOverride;
  final String? avatarAsset;

  /// Optional concrete network identity. Bitcoin-family contexts all use the
  /// same secp256k1 account id, so the chain string alone is not enough to
  /// switch libwallet onto the correct receive/send network.
  final String? networkId;
  final String? networkChainId;
  final String? networkName;
  final String? networkSymbol;
  final bool isMainWalletContext;

  const UnifiedAccount({
    required this.backend,
    required this.chain,
    required this.address,
    required this.label,
    this.walletName = '',
    this.accountName = '',
    this.accountIndex,
    this.walletId,
    this.accountId,
    this.curve,
    this.idOverride,
    this.avatarAsset,
    this.networkId,
    this.networkChainId,
    this.networkName,
    this.networkSymbol,
    this.isMainWalletContext = false,
  });

  bool get isInApp => backend == AccountBackend.inapp;
  bool get isMwa => backend == AccountBackend.mwa;
  bool get isSolana => chain == 'solana';

  bool get isVirtual => idOverride != null;

  /// Stable identity: in-app → `accountId`; virtual in-app contexts can
  /// override this; MWA → `"mwa:<address>"`.
  String get id => idOverride ?? (isInApp ? accountId! : 'mwa:$address');

  @override
  String toString() => 'UnifiedAccount($id, $backend, $chain, "$label")';
}

/// Label shown for the external Seed Vault account.
const String mwaAccountLabel = 'External (Seed Vault)';

class BitcoinNetworkContext {
  final String chain;
  final String chainId;
  final String label;
  final String symbol;
  final String? networkId;

  const BitcoinNetworkContext({
    required this.chain,
    required this.chainId,
    required this.label,
    required this.symbol,
    this.networkId,
  });
}

const List<String> kBitcoinFamilyChainOrder = [
  'bitcoin',
  'bitcoin-cash',
  'dogecoin',
  'litecoin',
];

const List<BitcoinNetworkContext> kDefaultBitcoinFamilyContexts = [
  BitcoinNetworkContext(
    chain: 'bitcoin',
    chainId: 'bitcoin',
    label: 'Bitcoin',
    symbol: 'BTC',
  ),
  BitcoinNetworkContext(
    chain: 'bitcoin-cash',
    chainId: 'bitcoin-cash',
    label: 'Bitcoin Cash',
    symbol: 'BCH',
  ),
  BitcoinNetworkContext(
    chain: 'dogecoin',
    chainId: 'dogecoin',
    label: 'Dogecoin',
    symbol: 'DOGE',
  ),
  BitcoinNetworkContext(
    chain: 'litecoin',
    chainId: 'litecoin',
    label: 'Litecoin',
    symbol: 'LTC',
  ),
];

bool isBitcoinFamilyChain(String? chain) =>
    chain != null && kBitcoinFamilyChainOrder.contains(chain);

String bitcoinContextId(String chain, String accountId) => '$chain:$accountId';

String? bitcoinFamilyChainForNetwork(Network network) {
  if (network.type != NetworkType.bitcoin) return null;
  final chainId = network.chainId.toLowerCase();
  final symbol = network.currencySymbol.toUpperCase();
  if (chainId == 'bitcoin' || symbol == 'BTC') return 'bitcoin';
  if (chainId == 'bitcoin-cash' || symbol == 'BCH') return 'bitcoin-cash';
  if (chainId == 'dogecoin' || symbol == 'DOGE') return 'dogecoin';
  if (chainId == 'litecoin' || symbol == 'LTC') return 'litecoin';
  return null;
}

List<BitcoinNetworkContext> bitcoinContextsFromNetworks(
  Iterable<Network> networks,
) {
  final byChain = <String, BitcoinNetworkContext>{};
  for (final network in networks) {
    if (network.testNet) continue;
    final chain = bitcoinFamilyChainForNetwork(network);
    if (chain == null) continue;
    if (byChain.containsKey(chain)) continue;
    byChain[chain] = BitcoinNetworkContext(
      chain: chain,
      chainId: network.chainId,
      label: chainLabel(chain),
      symbol: chainTicker(chain),
      networkId: network.id,
    );
  }
  return [
    for (final chain in kBitcoinFamilyChainOrder)
      if (byChain[chain] != null) byChain[chain]!,
  ];
}

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
/// - its parent wallet is missing from `wallets.list()`; or
/// - its `type` isn't allowed for the parent wallet's curve
///   ([allowedAccountTypesForCurve]) — the principled, network-independent
///   check.
bool isUsableAccount(Account account, Wallet? wallet) {
  if (wallet == null) return false;
  if (!isUsableAccountAddress(account.address)) return false;
  if (account.type == 'ethereum' && !account.address.startsWith('0x')) {
    return false;
  }
  final curve = wallet.curve;
  if (!allowedAccountTypesForCurve(curve).contains(account.type)) {
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
  String? currentAccountId,
  NetworkType? currentNetworkType,
  String? currentNetworkChainId,
  String? currentAddress,
  Map<String, String> bitcoinAddressesByAccountId = const {},
  Map<String, String> bitcoinAddressesByContextId = const {},
  Map<String, String> preferredChainsByAccountId = const {},
  Map<String, String> accountAvatarAssetsById = const {},
  List<BitcoinNetworkContext> bitcoinNetworkContexts =
      kDefaultBitcoinFamilyContexts,
}) {
  final out = <UnifiedAccount>[];
  final bitcoinContexts = <UnifiedAccount>[];
  for (final a in inappAccounts) {
    final w = walletsById[a.wallet];
    // Skip phantom accounts (curve/type mismatch, non-0x EVM address, or
    // "N/A" — see [isUsableAccount]); they can't be displayed or transacted on.
    if (!isUsableAccount(a, w)) continue;
    final preferredChain = preferredChainsByAccountId[a.id];
    final walletName = w?.name ?? '';
    final accountName = _displayAccountName(a.name, a.type, a.index);
    final label = _accountLabel(
      walletName: walletName,
      accountName: a.name,
      accountIndex: a.index,
      fallbackChain: a.type,
    );
    final isMainAccount = a.index == 0;
    final hideRealForBitcoinContext =
        !isMainAccount &&
        a.type == 'ethereum' &&
        w?.curve == 'secp256k1' &&
        isBitcoinFamilyChain(preferredChain);
    if (!hideRealForBitcoinContext) {
      out.add(
        UnifiedAccount(
          backend: AccountBackend.inapp,
          chain: a.type,
          address: a.address,
          label: label,
          walletName: walletName,
          accountName: accountName,
          accountIndex: a.index,
          walletId: a.wallet,
          accountId: a.id,
          curve: w?.curve,
          avatarAsset: accountAvatarAssetsById[a.id],
          isMainWalletContext: isMainAccount,
        ),
      );
    }
    if (a.type == 'ethereum' && w?.curve == 'secp256k1' && isMainAccount) {
      for (final context in bitcoinNetworkContexts) {
        final id = bitcoinContextId(context.chain, a.id);
        final activeBitcoinFamilyAddress =
            currentAccountId == a.id &&
                currentNetworkType == NetworkType.bitcoin &&
                _networkChainMatchesContext(
                  currentNetworkChainId,
                  context.chain,
                ) &&
                isBitcoinFamilyAddress(currentAddress)
            ? currentAddress!.trim()
            : null;
        final bitcoinAddress =
            activeBitcoinFamilyAddress ??
            bitcoinAddressesByContextId[id] ??
            (context.chain == 'bitcoin'
                ? bitcoinAddressesByAccountId[a.id] ?? ''
                : '');
        bitcoinContexts.add(
          UnifiedAccount(
            backend: AccountBackend.inapp,
            chain: context.chain,
            address: bitcoinAddress,
            label: _accountLabel(
              walletName: walletName,
              accountName: a.name,
              accountIndex: a.index,
              fallbackChain: context.chain,
            ),
            walletName: walletName,
            accountName: chainLabel(context.chain),
            accountIndex: a.index,
            walletId: a.wallet,
            accountId: a.id,
            curve: w?.curve,
            idOverride: id,
            avatarAsset: accountAvatarAssetsById[id],
            networkId: context.networkId,
            networkChainId: context.chainId,
            networkName: context.label,
            networkSymbol: context.symbol,
            isMainWalletContext: true,
          ),
        );
      }
    }
  }
  out.addAll(bitcoinContexts);
  if (mwaAddress != null && mwaAddress.isNotEmpty) {
    out.add(
      UnifiedAccount(
        backend: AccountBackend.mwa,
        chain: 'solana',
        address: mwaAddress,
        label: mwaAccountLabel,
        accountName: mwaAccountLabel,
      ),
    );
  }
  return out;
}

String _accountLabel({
  required String walletName,
  required String accountName,
  required int accountIndex,
  required String fallbackChain,
}) {
  final wallet = walletName.trim();
  final account = _displayAccountName(accountName, fallbackChain, accountIndex);
  return wallet.isEmpty ? account : '$wallet - $account';
}

String _displayAccountName(String accountName, String chain, int accountIndex) {
  final trimmed = accountName.trim();
  final lower = trimmed.toLowerCase();
  final isNetworkName = [
    'solana',
    'ethereum',
    ...kBitcoinFamilyChainOrder,
  ].any((network) => lower == chainLabel(network).toLowerCase());
  if (trimmed.isEmpty ||
      lower == chainLabel(chain).toLowerCase() ||
      isNetworkName) {
    return suggestAccountName(accountIndex);
  }
  return trimmed;
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
  NetworkType? activeNetworkType,
  String? activeNetworkChainId,
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
    if (activeNetworkType != null) {
      for (final a in accounts) {
        if (a.isInApp &&
            a.accountId == activeInAppAccountId &&
            accountMatchesNetwork(
              a,
              activeNetworkType,
              networkChainId: activeNetworkChainId,
            )) {
          return a;
        }
      }
    }
    for (final a in accounts) {
      if (a.isInApp && a.accountId == activeInAppAccountId) {
        return a;
      }
    }
  }
  return resolvePersistedAccount(accounts: accounts, savedId: savedId);
}

/// Account `type`s that can be derived for a wallet of the given [curve].
/// Bitcoin is a network context on the secp256k1 account, not a separate
/// account type in the app UI; creating a `bitcoin` account can surface a stale
/// EVM-shaped `0x` address. Empty for an unknown/absent curve.
List<String> allowedAccountTypesForCurve(String? curve) {
  switch (curve) {
    case 'ed25519':
      return const ['solana'];
    case 'secp256k1':
      return const ['ethereum'];
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

bool isBitcoinAddress(String? address) {
  final value = address?.trim();
  if (value == null || value.isEmpty) return false;
  final lower = value.toLowerCase();
  if (lower.startsWith('0x')) return false;
  if (lower.startsWith('bc1') ||
      lower.startsWith('tb1') ||
      lower.startsWith('bcrt1')) {
    return true;
  }
  return RegExp(r'^[13][a-km-zA-HJ-NP-Z1-9]{25,}$').hasMatch(value) ||
      RegExp(r'^[mn2][a-km-zA-HJ-NP-Z1-9]{25,}$').hasMatch(value);
}

bool isBitcoinFamilyAddress(String? address) {
  final value = address?.trim();
  if (value == null || value.isEmpty) return false;
  return !value.toLowerCase().startsWith('0x');
}

String? pickBitcoinAddress(Iterable<String> addresses) {
  for (final address in addresses) {
    if (isBitcoinAddress(address)) return address.trim();
  }
  return null;
}

/// The libwallet [NetworkType] an account of [chain] runs on. An account's
/// address only works while the current network matches this family — so
/// switching to a different-chain account needs a compatible network.
NetworkType networkTypeForChain(String chain) {
  switch (chain) {
    case 'ethereum':
      return NetworkType.evm;
    case 'bitcoin':
    case 'bitcoin-cash':
    case 'dogecoin':
    case 'litecoin':
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
  final networkId = account.networkId;
  if (networkId != null) {
    final exact = all.where((n) => n.id == networkId).toList();
    if (exact.isNotEmpty) return exact;
  }
  final t = networkTypeForChain(account.chain);
  return all.where((n) => n.type == t).toList();
}

/// Whether [networkType] matches [account]'s chain — i.e. the account is
/// usable on that network without a network switch.
bool accountMatchesNetwork(
  UnifiedAccount account,
  NetworkType networkType, {
  String? networkChainId,
}) {
  if (networkTypeForChain(account.chain) != networkType) return false;
  if (networkType == NetworkType.bitcoin && networkChainId != null) {
    return _networkChainMatchesContext(networkChainId, account.chain);
  }
  return true;
}

bool _networkChainMatchesContext(String? networkChainId, String accountChain) {
  if (networkChainId == null) return true;
  final lower = networkChainId.toLowerCase();
  switch (accountChain) {
    case 'bitcoin':
      return lower == 'bitcoin';
    case 'bitcoin-cash':
      return lower == 'bitcoin-cash';
    case 'dogecoin':
      return lower == 'dogecoin';
    case 'litecoin':
      return lower == 'litecoin';
    default:
      return true;
  }
}

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
    case 'bitcoin-cash':
      return 'Bitcoin Cash';
    case 'dogecoin':
      return 'Dogecoin';
    case 'litecoin':
      return 'Litecoin';
    default:
      return chain.isEmpty ? '' : chain[0].toUpperCase() + chain.substring(1);
  }
}

String chainTicker(String chain) {
  switch (chain) {
    case 'solana':
      return 'SOL';
    case 'ethereum':
      return 'ETH';
    case 'bitcoin':
      return 'BTC';
    case 'bitcoin-cash':
      return 'BCH';
    case 'dogecoin':
      return 'DOGE';
    case 'litecoin':
      return 'LTC';
    default:
      return chainLabel(chain).toUpperCase();
  }
}
