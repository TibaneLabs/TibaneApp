import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/logical_wallet.dart';
import '../../services/wallet/unified_account.dart';
import '../../services/wallet_service.dart';
import '../../utils/context_extensions.dart';

/// Find the Solana context that belongs to the same logical Tibane wallet as
/// the current account. Falls back to any available Solana account when the
/// current context cannot be grouped.
@visibleForTesting
UnifiedAccount? solanaContextForWallet(WalletService wallet) {
  final current = wallet.currentAccount;
  if (current == null || current.isSolana) return current;

  final accounts = wallet.accounts;
  final currentWalletId = current.walletId;
  if (current.isInApp && currentWalletId != null) {
    final groups = buildLogicalWallets(
      wallet.accountsService.walletsById.values,
    );
    for (final group in groups) {
      if (!group.containsWallet(currentWalletId)) continue;
      for (final account in accounts) {
        final walletId = account.walletId;
        if (account.isInApp &&
            account.isSolana &&
            walletId != null &&
            group.containsWallet(walletId)) {
          return account;
        }
      }
    }
  }

  for (final account in accounts) {
    if (account.isMwa && account.isSolana) return account;
  }
  for (final account in accounts) {
    if (account.isInApp && account.isSolana) return account;
  }
  return null;
}

/// Solana-only tools remain visible from any selected account, but they must
/// run with a Solana signing context. This switches quietly when possible and
/// shows a localized error only when no Solana context exists.
Future<bool> ensureSolanaWalletContext(BuildContext context) async {
  final wallet = context.read<WalletService>();
  if (wallet.solanaFeaturesEnabled) return true;

  final l10n = context.l10n;
  final messenger = context.messenger;
  final target = solanaContextForWallet(wallet);
  if (target == null) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.homeSolanaAccountUnavailable)),
    );
    return false;
  }

  final ok = await wallet.setCurrentAccount(target);
  if (!ok) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.homeSolanaAccountUnavailable)),
    );
  }
  return ok;
}
