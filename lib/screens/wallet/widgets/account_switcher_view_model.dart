import 'package:libwallet/libwallet.dart' show Wallet;

import '../../../services/wallet/logical_wallet.dart';
import '../../../services/wallet/unified_account.dart';

/// Pure presentation logic for the account switcher — grouping, ordering, and
/// account-creation rules. Kept out of the widget layer so it is unit-testable
/// and recomputed inputs are explicit (see `account_switcher_sheet.dart`).

/// One logical wallet's accounts, split into its native per-chain contexts
/// ([mainAccounts]) and user-created extra accounts ([additionalAccounts]).
class AccountSwitcherGroup {
  final String id;
  final String walletName;
  final List<UnifiedAccount> mainAccounts;
  final List<UnifiedAccount> additionalAccounts;

  const AccountSwitcherGroup({
    required this.id,
    required this.walletName,
    required this.mainAccounts,
    required this.additionalAccounts,
  });
}

/// Group the in-app [accounts] by logical wallet (Solana + EVM created
/// together), with native contexts in network order and additional accounts in
/// creation order. In-app accounts not matching any logical wallet are collected
/// into a trailing [unnamedLabel] group. MWA/external accounts are excluded —
/// the sheet renders those separately.
List<AccountSwitcherGroup> buildAccountGroups({
  required List<UnifiedAccount> accounts,
  required Iterable<Wallet> wallets,
  required String unnamedLabel,
  Map<String, String> attachedWalletParents = const {},
  Map<String, String> walletGroups = const {},
}) {
  final logicalWallets = buildLogicalWallets(
    wallets,
    attachedWalletParents: attachedWalletParents,
    walletGroups: walletGroups,
  );
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
        id: logicalWallet.id,
        walletName: logicalWallet.displayName(unnamedLabel),
        mainAccounts:
            walletAccounts
                .where(
                  (a) =>
                      a.isMainWalletContext &&
                      !attachedWalletParents.containsKey(a.walletId),
                )
                .toList()
              ..sort(compareAccountsForSwitcher),
        additionalAccounts: _accountsInCreationOrder(
          walletAccounts.where(
            (a) =>
                !a.isMainWalletContext ||
                attachedWalletParents.containsKey(a.walletId),
          ),
        ),
      ),
    );
  }

  final leftovers = accounts
      .where((a) => a.isInApp && !usedIds.contains(a.id))
      .toList();
  if (leftovers.isNotEmpty) {
    groups.add(
      AccountSwitcherGroup(
        id: 'unmatched-in-app-accounts',
        walletName: unnamedLabel,
        mainAccounts: leftovers.where((a) => a.isMainWalletContext).toList()
          ..sort(compareAccountsForSwitcher),
        additionalAccounts: _accountsInCreationOrder(
          leftovers.where((a) => !a.isMainWalletContext),
        ),
      ),
    );
  }
  return groups;
}

List<UnifiedAccount> _accountsInCreationOrder(
  Iterable<UnifiedAccount> accounts,
) {
  final indexed = accounts.indexed.toList()
    ..sort((a, b) {
      final first = a.$2.createdAt;
      final second = b.$2.createdAt;
      final created = first == null
          ? (second == null ? 0 : 1)
          : second == null
          ? -1
          : first.compareTo(second);
      if (created != 0) return created;
      // Keep the source order for tied or unavailable creation timestamps.
      return a.$1.compareTo(b.$1);
    });
  return [for (final (_, account) in indexed) account];
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

/// Chains available in the create-account flow. libwallet derives each new
/// account from the selected curve wallet at its next free account index.
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
