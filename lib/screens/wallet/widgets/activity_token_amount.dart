import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../constants/solana_constants.dart';
import '../../../models/transaction_activity.dart';
import '../../../services/balances_store.dart';
import '../../../services/wallet_service.dart';
import '../../../theme/tibane_theme.dart';
import '../../../widgets/token_icon.dart';

class ActivityTokenAmount extends StatelessWidget {
  const ActivityTokenAmount({
    super.key,
    required this.change,
    this.compact = false,
  });
  final ActivityTokenChange change;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final holdings = context.watch<BalancesStore>().holdings;
    final wallet = context.watch<WalletService>();
    final holding = holdings.where((h) => h.mint == change.mint).firstOrNull;
    final asset = wallet.assets
        .where(
          (a) =>
              a.tokenAddress == change.mint ||
              a.key.endsWith('.${change.mint}'),
        )
        .firstOrNull;
    final symbol =
        change.symbol ??
        holding?.symbol ??
        asset?.symbol ??
        (change.mint == wsolMint ? 'SOL' : shortenAddress(change.mint));
    final amount = formatActivityAmount(
      change.amount.abs(),
      change.decimals,
      maxDecimals: compact ? 4 : null,
    );
    final color = change.amount.isNegative
        ? TibaneColors.error
        : TibaneColors.cyan;
    return Row(
      mainAxisAlignment: compact
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        if (!compact) ...[
          TokenIcon(
            mint: change.mint,
            symbol: symbol,
            imageUrl: change.imageUrl ?? holding?.imageUrl,
            size: 40,
          ),
          const SizedBox(width: 12),
        ],
        Flexible(
          child: Text(
            '${change.amount.isNegative ? '-' : '+'}$amount $symbol',
            textAlign: compact ? TextAlign.end : TextAlign.start,
            style: TextStyle(
              color: color,
              fontSize: compact ? 13 : 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
