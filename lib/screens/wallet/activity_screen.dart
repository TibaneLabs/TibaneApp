import 'dart:async';

import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart'
    show Network, NetworkType, Transaction;
import 'package:provider/provider.dart';

import '../../constants/solana_constants.dart';
import '../../l10n/l10n.dart';
import '../../models/transaction_activity.dart';
import '../../services/activity_history_cache.dart';
import '../../services/balances_store.dart';
import '../../services/jupiter_service.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/context_extensions.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/token_icon.dart';
import '../../widgets/tx_success.dart';
import 'transaction_details_screen.dart';
import 'widgets/activity_token_amount.dart';

String? activityExplorerUrl(
  String? address,
  Network? network, {
  bool externalSolana = false,
}) {
  if (address == null || address.isEmpty) return null;
  if (externalSolana) return solscanAccountUrl(address);
  if (network?.type == NetworkType.solana) {
    final base = Uri.parse(solscanAccountUrl(address));
    return network?.testNet == true
        ? base
              .replace(queryParameters: {'cluster': network!.chainId})
              .toString()
        : base.toString();
  }
  final url = network?.addressUrl(address);
  return url == null || url.isEmpty ? null : url;
}

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key, this.active = true});
  final bool active;

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.active) _refreshAfterFrame();
  }

  @override
  void didUpdateWidget(ActivityScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _refreshAfterFrame();
  }

  void _refreshAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) {
        unawaited(context.read<BalancesStore>().refreshHistory());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wallet = context.watch<WalletService>();
    final store = context.watch<BalancesStore>();
    final address = wallet.publicKey;
    final url = activityExplorerUrl(
      address,
      wallet.libwallet.currentNetwork,
      externalSolana: wallet.kind != WalletKind.inapp,
    );
    return RefreshIndicator(
      color: TibaneColors.orange,
      onRefresh: store.refreshHistory,
      child: ListView(
        key: const Key('activity-history-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            l10n.dashboardTabActivity,
            style: context.textTheme.headlineSmall,
          ),
          const SizedBox(height: 20),
          if (store.historyFailed) ...[
            Text(
              l10n.activityRefreshFailed,
              style: const TextStyle(color: TibaneColors.textMuted),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: store.refreshHistory,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.actionRetry),
              ),
            ),
          ],
          if (store.loadingTxs && store.transactions.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: CircularProgressIndicator(color: TibaneColors.orange),
              ),
            )
          else if (store.transactions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text(l10n.dashboardNoTransactions)),
            )
          else
            for (final tx in store.transactions.take(activityHistoryLimit))
              _TransactionRow(
                tx: tx,
                myAddr: address ?? '',
                tokenInfo: _resolveTokenInfo(tx, wallet, store.holdings),
              ),
          if (url != null) ...[
            const SizedBox(height: 12),
            Center(
              child: TextButton.icon(
                key: const Key('activity-view-all'),
                onPressed: () => openExplorerUrl(context, url),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(l10n.activityViewAll),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Resolve display info (symbol + icon) for a transaction's asset by
  /// joining `tx.asset` against the data we've already loaded: the
  /// libwallet `Asset` list for native + tracked tokens, and Jupiter
  /// `_holdings` for everything else. Falls back to the active
  /// network's native ticker when nothing matches (libwallet's tx
  /// table is shared across networks and the asset key may reference
  /// a chain we haven't fetched assets for yet).
  _TxTokenInfo _resolveTokenInfo(
    Transaction tx,
    WalletService wallet,
    List<TokenHolding> holdings,
  ) {
    final assetKey = tx.asset;
    final lastDot = assetKey.lastIndexOf('.');
    final tail = lastDot >= 0 ? assetKey.substring(lastDot + 1) : assetKey;
    final isNative = tail == 'NATIVE';
    // Native Solana → swap in wSOL's mint so TokenIcon's
    // `mint == wsolMint` branch picks up the bundled sol.png.
    // Without this the row would land on the letter-S placeholder
    // since libwallet doesn't carry a logo URL for native assets.
    final isNativeSol = isNative && assetKey.startsWith('solana.');

    for (final a in wallet.assets) {
      if (a.key == assetKey) {
        return _TxTokenInfo(
          symbol: a.symbol,
          mint: isNativeSol ? wsolMint : (isNative ? null : a.tokenAddress),
          imageUrl: null,
          isNative: isNative,
        );
      }
    }
    if (!isNative) {
      for (final h in holdings) {
        if (h.mint == tail) {
          return _TxTokenInfo(
            symbol: h.symbol.isNotEmpty ? h.symbol : h.name,
            mint: h.mint,
            imageUrl: h.imageUrl,
            isNative: false,
          );
        }
      }
    }
    final net = wallet.libwallet.currentNetwork;
    return _TxTokenInfo(
      symbol: isNative
          ? (net?.currencySymbol.isNotEmpty == true ? net!.currencySymbol : '')
          : '',
      mint: isNativeSol ? wsolMint : (isNative ? null : tail),
      imageUrl: null,
      isNative: isNative,
    );
  }
}

class _TxTokenInfo {
  final String symbol;
  final String? mint;
  final String? imageUrl;
  final bool isNative;

  const _TxTokenInfo({
    required this.symbol,
    required this.mint,
    required this.imageUrl,
    required this.isNative,
  });
}

class _TransactionRow extends StatelessWidget {
  final Transaction tx;
  final String myAddr;
  final _TxTokenInfo tokenInfo;

  const _TransactionRow({
    required this.tx,
    required this.myAddr,
    required this.tokenInfo,
  });

  bool get _isSend => tx.asset.startsWith('evm.')
      ? tx.from.toLowerCase() == myAddr.toLowerCase()
      : tx.from == myAddr;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final activity = context.watch<BalancesStore>().activityFor(tx);
    final isSolana = tx.asset.startsWith('solana.');
    final kind =
        activity?.kind ??
        (isSolana
            ? ActivityKind.transaction
            : _isSend
            ? ActivityKind.sent
            : ActivityKind.received);
    final label = activity?.failed == true
        ? l10n.activityFailed
        : switch (kind) {
            ActivityKind.swap => l10n.swapButton,
            ActivityKind.sent => l10n.dashboardTxSent,
            ActivityKind.received => l10n.dashboardTxReceived,
            ActivityKind.transaction => l10n.labelTransaction,
          };
    final counterparty =
        kind == ActivityKind.swap || kind == ActivityKind.transaction
        ? tx.hash ?? tx.id
        : kind == ActivityKind.sent
        ? activity?.recipient ?? tx.to
        : activity?.sender ?? tx.from;
    final amt = tx.amount;
    final amountStr = amt != null && !amt.isMax
        ? formatActivityAmount(amt.value.abs(), amt.exp, maxDecimals: 4)
        : '';
    final fiatStr = !isSolana && tx.fiatAmount != null
        ? '\$${tx.fiatAmount!.toDouble().toStringAsFixed(2)}'
        : null;
    final created = (activity?.created ?? tx.created)?.toLocal();
    final timeStr = created != null
        ? '${created.month}/${created.day} ${created.hour}:${created.minute.toString().padLeft(2, '0')}'
        : '';
    final amountColor = kind == ActivityKind.sent
        ? TibaneColors.error
        : TibaneColors.cyan;
    final amountLine = StringBuffer(kind == ActivityKind.sent ? '-' : '+')
      ..write(amountStr);
    if (tokenInfo.symbol.isNotEmpty) {
      amountLine
        ..write(' ')
        ..write(tokenInfo.symbol);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TibaneCard(
        key: Key('activity-transaction-${tx.id}'),
        padding: const EdgeInsets.all(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TransactionDetailsScreen(
              transaction: tx,
              owner: myAddr,
              network: context.read<WalletService>().libwallet.currentNetwork,
            ),
          ),
        ),
        child: Row(
          children: [
            if (kind == ActivityKind.swap)
              Container(
                key: Key('activity-swap-icon-${tx.id}'),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: TibaneColors.orange.withValues(alpha: 0.1),
                ),
                child: const Icon(
                  Icons.swap_horiz,
                  size: 24,
                  color: TibaneColors.orange,
                ),
              )
            else if (kind == ActivityKind.transaction)
              Icon(
                Icons.receipt_long_outlined,
                size: 32,
                color: TibaneColors.orange,
              )
            else
              Stack(
                clipBehavior: Clip.none,
                children: [
                  TokenIcon(
                    imageUrl: tokenInfo.imageUrl,
                    mint: tokenInfo.mint ?? '',
                    symbol: tokenInfo.symbol,
                    size: 32,
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: TibaneColors.card,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        kind == ActivityKind.sent
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: 12,
                        color: amountColor,
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13 * 1.15,
                    ),
                  ),
                  Text(
                    shortenAddress(counterparty),
                    style: monoStyle(
                      fontSize: 11,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (activity != null)
                    for (final change in [
                      ...activity.changes.where((c) => c.amount.isNegative),
                      ...activity.changes.where((c) => !c.amount.isNegative),
                    ])
                      ActivityTokenAmount(change: change, compact: true)
                  else if (!isSolana)
                    Text(
                      amountLine.toString(),
                      style: TextStyle(
                        color: amountColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  if (fiatStr != null)
                    Text(
                      fiatStr,
                      style: monoStyle(
                        fontSize: 11,
                        color: TibaneColors.textMuted,
                      ),
                    ),
                  if (timeStr.isNotEmpty)
                    Text(
                      timeStr,
                      style: monoStyle(
                        fontSize: 10,
                        color: TibaneColors.textDim,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
