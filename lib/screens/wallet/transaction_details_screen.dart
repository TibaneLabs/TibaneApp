import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show Transaction, Network;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../models/transaction_activity.dart';
import '../../services/balances_store.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tx_success.dart';
import 'widgets/activity_token_amount.dart';

class TransactionDetailsScreen extends StatefulWidget {
  const TransactionDetailsScreen({
    super.key,
    required this.transaction,
    required this.owner,
    this.network,
  });
  final Transaction transaction;
  final String owner;
  final Network? network;

  @override
  State<TransactionDetailsScreen> createState() =>
      _TransactionDetailsScreenState();
}

class _TransactionDetailsScreenState extends State<TransactionDetailsScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    await context.read<BalancesStore>().loadActivity(widget.transaction);
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tx = widget.transaction;
    final activity = context.watch<BalancesStore>().activityFor(tx);
    final isSolana = tx.asset.startsWith('solana.');
    final isSend = tx.asset.startsWith('evm.')
        ? tx.from.toLowerCase() == widget.owner.toLowerCase()
        : tx.from == widget.owner;
    final kind =
        activity?.kind ??
        (isSolana
            ? ActivityKind.transaction
            : isSend
            ? ActivityKind.sent
            : ActivityKind.received);
    final title = switch (kind) {
      ActivityKind.swap => l10n.swapButton,
      ActivityKind.sent => l10n.dashboardTxSent,
      ActivityKind.received => l10n.dashboardTxReceived,
      ActivityKind.transaction => l10n.labelTransaction,
    };
    final hash = tx.hash;
    final url = hash == null || hash.isEmpty
        ? null
        : isSolana
        ? solscanTxUrl(hash)
        : explorerTxUrl(widget.network, hash);
    final sender = activity?.sender ?? tx.from;
    final recipient = activity?.recipient ?? tx.to;
    final created = (activity?.created ?? tx.created)?.toLocal();
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.activityDetailsTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            if (activity != null)
              Center(
                child: activity.failed
                    ? const Icon(
                        Icons.error_outline,
                        color: TibaneColors.error,
                        size: 64,
                      )
                    : txSuccessMark(size: 72),
              ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            ),
            if (activity != null) ...[
              const SizedBox(height: 8),
              Text(
                activity.failed ? l10n.activityFailed : l10n.activityConfirmed,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: activity.failed
                      ? TibaneColors.error
                      : TibaneColors.cyan,
                ),
              ),
            ],
            const SizedBox(height: 24),
            if (_loading && activity == null)
              const Center(
                child: CircularProgressIndicator(color: TibaneColors.orange),
              ),
            if (activity != null && activity.changes.isNotEmpty) ...[
              Text(
                l10n.activityAmount,
                style: monoStyle(color: TibaneColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              for (final change in [
                ...activity.changes.where((c) => c.amount.isNegative),
                ...activity.changes.where((c) => !c.amount.isNegative),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: ActivityTokenAmount(change: change),
                ),
            ] else if (!_loading && isSolana && activity == null) ...[
              Text(
                l10n.activityUnavailable,
                style: const TextStyle(color: TibaneColors.textMuted),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.actionRetry),
                ),
              ),
            ] else if (!isSolana && tx.amount != null) ...[
              _field(
                l10n.activityAmount,
                '${formatActivityAmount(tx.amount!.value, tx.amount!.exp)} ${tx.asset}',
              ),
            ],
            if (sender.isNotEmpty)
              _field(l10n.activitySender, sender, copy: true),
            if (recipient.isNotEmpty)
              _field(l10n.activityRecipient, recipient, copy: true),
            if (activity != null)
              _field(
                l10n.activityFee,
                '${formatActivityAmount(activity.fee, 9)} SOL',
              ),
            if (created != null)
              _field(
                l10n.activityDate,
                '${MaterialLocalizations.of(context).formatFullDate(created)} '
                '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(created))}',
              ),
            _field(
              l10n.labelNetwork,
              isSolana ? 'Solana' : widget.network?.name ?? tx.network ?? '--',
            ),
            if (hash != null && hash.isNotEmpty)
              _field(l10n.labelTransactionId, hash, copy: true),
            if (url != null)
              Center(
                child: txExplorerLink(
                  onTap: () => openExplorerUrl(context, url),
                  label: isSolana
                      ? l10n.viewOnExplorerNamed('Solscan')
                      : l10n.viewOnExplorer,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, String value, {bool copy = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: monoStyle(fontSize: 12, color: TibaneColors.textMuted),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: SelectableText(
                value,
                style: monoStyle(fontSize: 13, color: TibaneColors.text),
              ),
            ),
            if (copy)
              IconButton(
                icon: const Icon(Icons.copy_outlined, size: 20),
                tooltip: context.l10n.actionCopy,
                onPressed: () => copyWithToast(context, value, label),
              ),
          ],
        ),
      ],
    ),
  );
}
