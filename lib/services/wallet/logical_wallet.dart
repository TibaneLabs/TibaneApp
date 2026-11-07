import 'package:libwallet/libwallet.dart' show Wallet;
import 'wallet_export_format.dart' show isNormalMnemonicWallet;

enum WalletContentsKind { native, added, imported }

/// User-facing origin for a technical wallet contained in a logical wallet.
/// Imported private keys are represented by a single-share wallet, while
/// older additional-account flows may be attached as their own wallet.
WalletContentsKind walletContentsKind(
  Wallet wallet, {
  Map<String, String> attachedWalletParents = const {},
}) {
  if (wallet.keys.length == 1 && !isNormalMnemonicWallet(wallet)) {
    return WalletContentsKind.imported;
  }
  if (attachedWalletParents.containsKey(wallet.id)) {
    return WalletContentsKind.added;
  }
  return WalletContentsKind.native;
}

/// A user-facing Tibane wallet can be backed by two libwallet wallets: ed25519
/// for Solana and secp256k1 for Ethereum/Bitcoin.
class LogicalWallet {
  LogicalWallet(List<Wallet> wallets)
    : wallets = sortWalletsForDisplay(wallets);

  final List<Wallet> wallets;

  String get id => wallets.map((w) => w.id).join('|');

  String displayName(String unnamedLabel) {
    final raw = wallets.first.name.trim();
    return raw.isEmpty ? unnamedLabel : raw;
  }

  bool containsWallet(String walletId) =>
      wallets.any((wallet) => wallet.id == walletId);

  List<String> get chains {
    final out = <String>[];
    final seen = <String>{};
    for (final wallet in wallets) {
      for (final chain in chainsForWallet(wallet)) {
        if (seen.add(chain)) out.add(chain);
      }
    }
    return out;
  }

  Wallet? walletForChain(String chain) {
    final curve = switch (chain) {
      'solana' => 'ed25519',
      'ethereum' ||
      'bitcoin' ||
      'bitcoin-cash' ||
      'dogecoin' ||
      'litecoin' => 'secp256k1',
      _ => null,
    };
    if (curve == null) return null;
    for (final wallet in wallets) {
      if (wallet.curve == curve) return wallet;
    }
    return null;
  }
}

List<LogicalWallet> buildLogicalWallets(
  Iterable<Wallet> wallets, {
  Map<String, String> attachedWalletParents = const {},
  Map<String, String> walletGroups = const {},
}) {
  final list = wallets.toList();
  final used = <String>{};
  final groups = <LogicalWallet>[];
  final attachedIds = attachedWalletParents.keys.toSet();
  for (final wallet in list) {
    if (used.contains(wallet.id) || attachedIds.contains(wallet.id)) continue;
    final groupId = walletGroups[wallet.id];
    final groupWallets = groupId == null
        ? [wallet]
        : list
              .where(
                (candidate) =>
                    !used.contains(candidate.id) &&
                    !attachedIds.contains(candidate.id) &&
                    walletGroups[candidate.id] == groupId,
              )
              .toList();
    for (final grouped in groupWallets) {
      used.add(grouped.id);
    }
    groups.add(LogicalWallet(groupWallets));
  }

  // A private-key import has its own technical wallet. Keep it attached to the
  // logical wallet selected by the user instead of presenting it as an
  // unrelated top-level wallet. The relation is explicit and persisted by
  // AccountsService; name/time heuristics are never used here.
  for (final child in list.where((w) => attachedIds.contains(w.id))) {
    final parentId = attachedWalletParents[child.id];
    final groupIndex = groups.indexWhere(
      (group) => parentId != null && group.containsWallet(parentId),
    );
    if (groupIndex < 0) {
      groups.add(LogicalWallet([child]));
      continue;
    }
    groups[groupIndex] = LogicalWallet([...groups[groupIndex].wallets, child]);
  }
  return groups;
}

List<Wallet> sortWalletsForDisplay(List<Wallet> wallets) {
  final sorted = [...wallets];
  sorted.sort((a, b) {
    final curve = _curveRank(a.curve).compareTo(_curveRank(b.curve));
    if (curve != 0) return curve;
    return a.created.compareTo(b.created);
  });
  return sorted;
}

List<String> chainsForWallet(Wallet wallet) {
  switch (wallet.curve) {
    case 'ed25519':
      return const ['solana'];
    case 'secp256k1':
      return const [
        'ethereum',
        'bitcoin',
        'bitcoin-cash',
        'dogecoin',
        'litecoin',
      ];
    default:
      return const [];
  }
}

int _curveRank(String curve) {
  switch (curve) {
    case 'ed25519':
      return 0;
    case 'secp256k1':
      return 1;
    default:
      return 2;
  }
}
