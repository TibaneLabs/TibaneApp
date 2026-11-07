import 'dart:async';

import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show Network, NetworkType, Wallet;
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../services/wallet/unified_account.dart';
import '../../../services/wallet_service.dart';
import '../../../theme/tibane_theme.dart';
import '../../../widgets/network_logos.dart';
import 'account_switcher_view_model.dart';

/// Address selection only: never switches the active wallet or network.
Future<UnifiedAccount?> showSendAccountPicker(
  BuildContext context, {
  required Network network,
}) {
  final wallet = context.read<WalletService>();
  unawaited(wallet.refreshAccounts());
  return showModalBottomSheet<UnifiedAccount>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TibaneColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
    ),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.75,
      child: AnimatedBuilder(
        animation: wallet,
        builder: (context, _) => SendAccountPicker(
          network: network,
          accounts: wallet.accounts,
          senderAccountId: wallet.currentAccount?.id,
          senderAddress: wallet.currentAccount?.address ?? wallet.publicKey,
          wallets: wallet.accountsService.walletsById.values,
          attachedWalletParents: wallet.accountsService.attachedWalletParents,
        ),
      ),
    ),
  );
}

List<UnifiedAccount> sendRecipientsForNetwork(
  Iterable<UnifiedAccount> accounts,
  Network network, {
  String? senderAccountId,
  String? senderAddress,
}) {
  final chain = switch (network.type) {
    NetworkType.solana => 'solana',
    NetworkType.evm => 'ethereum',
    NetworkType.bitcoin => bitcoinFamilyChainForNetwork(network),
    NetworkType.tron => 'tron',
    NetworkType.unknown => null,
  };
  if (chain == null) return const [];
  String normalizedAddress(String address) => network.type == NetworkType.evm
      ? address.trim().toLowerCase()
      : address.trim();
  final sourceAddress = normalizedAddress(senderAddress ?? '');
  return accounts.where((account) {
    if (senderAccountId != null && account.id == senderAccountId) return false;
    if (sourceAddress.isNotEmpty &&
        normalizedAddress(account.address) == sourceAddress) {
      return false;
    }
    if (!isUsableAccountAddress(account.address)) return false;
    if (account.chain != chain &&
        !(network.type == NetworkType.evm && account.chain == 'evm')) {
      return false;
    }
    // Unbound EVM/Solana keys can receive on the selected network. A concrete
    // network binding, when present, must never be crossed by this picker.
    if (account.networkChainId != null &&
        account.networkChainId != network.chainId) {
      return false;
    }
    if (account.networkChainId == null &&
        account.networkId != null &&
        account.networkId != network.id) {
      return false;
    }
    return true;
  }).toList();
}

class SendAccountPicker extends StatelessWidget {
  final Network network;
  final List<UnifiedAccount> accounts;
  final Iterable<Wallet> wallets;
  final Map<String, String> attachedWalletParents;
  final String? senderAccountId;
  final String? senderAddress;

  const SendAccountPicker({
    super.key,
    required this.network,
    required this.accounts,
    required this.wallets,
    this.senderAccountId,
    this.senderAddress,
    this.attachedWalletParents = const {},
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final recipients = sendRecipientsForNetwork(
      accounts,
      network,
      senderAccountId: senderAccountId,
      senderAddress: senderAddress,
    );
    final groups = buildAccountGroups(
      accounts: recipients,
      wallets: wallets,
      unnamedLabel: l10n.walletsMgmtUnnamed,
      attachedWalletParents: attachedWalletParents,
    );
    final external = recipients.where((account) => account.isMwa).toList();
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sendChooseAccount,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        network.name,
                        style: const TextStyle(color: TibaneColors.textMuted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: l10n.actionClose,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: recipients.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        l10n.sendNoAccountsForNetwork(network.name),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: TibaneColors.textMuted),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      for (final group in groups) ...[
                        _GroupHeader(group.walletName),
                        for (final account in [
                          ...group.mainAccounts,
                          ...group.additionalAccounts,
                        ])
                          _RecipientTile(account: account),
                      ],
                      if (external.isNotEmpty) ...[
                        _GroupHeader(l10n.accountSwitcherExternalAccounts),
                        for (final account in external)
                          _RecipientTile(account: account),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String name;
  const _GroupHeader(this.name);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
    child: Text(
      name,
      style: monoStyle(
        fontSize: 16,
        color: TibaneColors.text,
      ).copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

class _RecipientTile extends StatelessWidget {
  final UnifiedAccount account;
  const _RecipientTile({required this.account});

  @override
  Widget build(BuildContext context) {
    final asset = orangeNetworkLogoAssetForChain(account.chain);
    final fallback = Icon(
      isBitcoinFamilyChain(account.chain)
          ? Icons.currency_bitcoin
          : Icons.account_balance_wallet_outlined,
      color: TibaneColors.orange,
      size: 22,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: TibaneColors.darker,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: ValueKey('send-recipient-${account.id}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => Navigator.pop(context, account),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: TibaneColors.orange.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: TibaneColors.orange.withValues(alpha: 0.24),
                    ),
                  ),
                  child: asset == null
                      ? fallback
                      : Image.asset(
                          asset,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => fallback,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        account.accountName.isNotEmpty
                            ? account.accountName
                            : account.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17.25,
                          fontWeight: FontWeight.w600,
                          color: TibaneColors.text,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        abbreviateAccountAddress(account.address),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          fontSize: 12.65,
                          color: TibaneColors.textMuted,
                        ).copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.chevron_right,
                  color: TibaneColors.textMuted,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
