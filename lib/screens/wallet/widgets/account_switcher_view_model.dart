import 'package:libwallet/libwallet.dart' show Wallet;

import '../../../services/wallet/logical_wallet.dart';
import '../../../services/wallet/unified_account.dart';

/// Pure presentation logic for the account switcher — grouping, ordering, and
/// account-creation rules. Kept out of the widget layer so it is unit-testable
/// and recomputed inputs are explicit (see `account_switcher_sheet.dart`).

/// One logical wallet's accounts, split into its native per-chain contexts
/// ([mainAccounts]) and user-created extra accounts ([additionalAccounts]).
class AccountSwitcherGroup {
  final String walletName;
  final List<UnifiedAccount> mainAccounts;
  final List<UnifiedAccount> additionalAccounts;

  const AccountSwitcherGroup({
    required this.walletName,
    required this.mainAccounts,
    required this.additionalAccounts,
  });
}

/// Group the in-app [accounts] by logical wallet (Solana + EVM created
/// together), each split into main contexts vs additional accounts and sorted
/// for display. In-app accounts not matching any logical wallet are collected
/// into a trailing [unnamedLabel] group. MWA/external accounts are excluded —
/// the sheet renders those separately.
List<AccountSwitcherGroup> buildAccountGroups({
  required List<UnifiedAccount> accounts,
  required Iterable<Wallet> wallets,
  required String unnamedLabel,
}) {
  final logicalWallets = buildLogicalWallets(wallets);
  final usedIds = <String>{};
  final groups = <AccountSwitcherGroup>[];

  for (final logicalWallet in logicalWallets) {
    final walletAccounts = accounts
        .where(
          (account) =>
              account.isInApp &&
              account.walletId != null &&
              logicalWallet.containsWallet(account.walletId!),
        )
        .toList();
    if (walletAccounts.isEmpty) continue;
    for (final account in walletAccounts) {
      usedIds.add(account.id);
    }
    groups.add(
      AccountSwitcherGroup(
        walletName: logicalWallet.displayName(unnamedLabel),
        mainAccounts:
            walletAccounts.where((a) => a.isMainWalletContext).toList()
              ..sort(compareAccountsForSwitcher),
        additionalAccounts:
            walletAccounts.where((a) => !a.isMainWalletContext).toList()
              ..sort(compareAccountsForSwitcher),
      ),
    );
  }

  final leftovers = accounts
      .where((a) => a.isInApp && !usedIds.contains(a.id))
      .toList()
    ..sort(compareAccountsForSwitcher);
  if (leftovers.isNotEmpty) {
    groups.add(
      AccountSwitcherGroup(
        walletName: unnamedLabel,
        mainAccounts: leftovers.where((a) => a.isMainWalletContext).toList(),
        additionalAccounts:
            leftovers.where((a) => !a.isMainWalletContext).toList(),
      ),
    );
  }
  return groups;
}

/// Stable switcher order: by chain ([_chainRank]), then account index, then id.
int compareAccountsForSwitcher(UnifiedAccount a, UnifiedAccount b) {
  final chain = _chainRank(a.chain).compareTo(_chainRank(b.chain));
  if (chain != 0) return chain;
  final index = (a.accountIndex ?? 0).compareTo(b.accountIndex ?? 0);
  if (index != 0) return index;
  return a.id.compareTo(b.id);
}

int _chainRank(String chain) {
  switch (chain) {
    case 'solana':
      return 0;
    case 'ethereum':
      return 1;
    case 'bitcoin':
      return 2;
    case 'bitcoin-cash':
      return 3;
    case 'dogecoin':
      return 4;
    case 'litecoin':
      return 5;
    default:
      return 99;
  }
}

/// Chains a new account can be created on for [group]: only the real key-bearing
/// curves (Solana / Ethereum). Bitcoin-family chains are network contexts over
/// the Ethereum account, not separate accounts.
List<String> creationChains(LogicalWallet group) => group.chains
    .where(
      (chain) =>
          (chain == 'solana' || chain == 'ethereum') &&
          group.walletForChain(chain) != null,
    )
    .toList();

/// The chain to preselect in the add-account form: a bitcoin-family [preferred]
/// maps to Ethereum (its key-bearing curve); otherwise [preferred] if creatable,
/// else the first available.
String initialChain(List<String> chains, String? preferred) {
  if (isBitcoinFamilyChain(preferred) && chains.contains('ethereum')) {
    return 'ethereum';
  }
  if (preferred != null && chains.contains(preferred)) return preferred;
  return chains.first;
}

/// The libwallet account type backing a [chain]: bitcoin-family chains ride the
/// `ethereum` (secp256k1) account; every other chain is its own type.
String accountTypeForChain(String chain) =>
    isBitcoinFamilyChain(chain) ? 'ethereum' : chain;
