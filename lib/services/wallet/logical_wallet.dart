import 'package:libwallet/libwallet.dart' show Wallet;

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

List<LogicalWallet> buildLogicalWallets(Iterable<Wallet> wallets) {
  final list = wallets.toList();
  final used = <String>{};
  final groups = <LogicalWallet>[];
  for (final wallet in list) {
    if (used.contains(wallet.id)) continue;
    final peer = _findCreatePeer(wallet, list, used);
    final groupWallets = peer == null ? [wallet] : [wallet, peer];
    for (final grouped in groupWallets) {
      used.add(grouped.id);
    }
    groups.add(LogicalWallet(groupWallets));
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

Wallet? _findCreatePeer(Wallet wallet, List<Wallet> wallets, Set<String> used) {
  if (wallet.name.trim().isEmpty) return null;
  final curve = wallet.curve;
  final peerCurve = switch (curve) {
    'ed25519' => 'secp256k1',
    'secp256k1' => 'ed25519',
    _ => null,
  };
  if (peerCurve == null) return null;
  Wallet? best;
  Duration? bestDiff;
  for (final candidate in wallets) {
    if (candidate.id == wallet.id || used.contains(candidate.id)) continue;
    if (candidate.curve != peerCurve) continue;
    if (candidate.name.trim() != wallet.name.trim()) continue;
    final diff = candidate.created.difference(wallet.created).abs();
    if (diff > const Duration(minutes: 10)) continue;
    if (bestDiff == null || diff < bestDiff) {
      best = candidate;
      bestDiff = diff;
    }
  }
  return best;
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
