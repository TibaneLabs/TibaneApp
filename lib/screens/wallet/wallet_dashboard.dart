import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show Asset, Transaction, TxHistoryUpdatedEvent;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../constants/solana_constants.dart';
import '../../services/uk_compliance_service.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../swap_screen.dart';
import 'receive_screen.dart';
import 'send_screen.dart';

class WalletDashboard extends StatefulWidget {
  const WalletDashboard({super.key});

  @override
  State<WalletDashboard> createState() => _WalletDashboardState();
}

class _WalletDashboardState extends State<WalletDashboard> {
  List<Asset> _assets = [];
  List<Transaction> _transactions = [];
  bool _loadingTxs = true;
  StreamSubscription<TxHistoryUpdatedEvent>? _txHistorySub;
  WalletService? _walletRef;

  @override
  void initState() {
    super.initState();
    _loadData();
    _subscribeHistory();
    // Reload on every "tx just committed" event from the swap/send flows.
    _walletRef = context.read<WalletService>();
    _walletRef!.swapCommittedTick.addListener(_onTxCommitted);
    // Register any on-chain tokens libwallet's auto-discovery missed so
    // they appear in the TOKENS section. Runs concurrently with the
    // initial _loadData; if any new mints land, it bumps
    // swapCommittedTick to trigger a second reload that sees them.
    unawaited(_walletRef!.discoverHoldings());
  }

  void _onTxCommitted() {
    if (!mounted) return;
    _loadData();
  }

  /// Listen for libwallet's tx-history backfill events. Fires whenever the
  /// background poller finds new on-chain activity for the active account.
  /// We just reload the dashboard so the new rows show up without the user
  /// having to pull-to-refresh.
  Future<void> _subscribeHistory() async {
    try {
      final wallet = context.read<WalletService>();
      final client = await wallet.libwallet.ensureClient();
      _txHistorySub = client.txHistoryUpdates.listen((_) {
        if (!mounted) return;
        _loadData();
      });
    } catch (e) {
      debugPrint('txHistoryUpdates subscribe failed: $e');
    }
  }

  @override
  void dispose() {
    _txHistorySub?.cancel();
    _walletRef?.swapCommittedTick.removeListener(_onTxCommitted);
    super.dispose();
  }

  Future<void> _loadData() async {
    final wallet = context.read<WalletService>();
    final lw = wallet.libwallet;
    try {
      final results = await Future.wait([
        lw.getAssets(),
        lw.getTransactions(limit: 50),
      ]);
      if (!mounted) return;
      final assets = results[0] as List<Asset>;
      debugPrint('[assets] getAssets returned ${assets.length} entries');
      for (final a in assets) {
        debugPrint(
          '[assets]   key=${a.key} symbol=${a.symbol} name=${a.name} '
          'amount=${a.amount} zero=${a.amount.isZero} '
          'native=${a.isNative} fiat=${a.fiatAmount}',
        );
      }
      final visible = assets
          .where((a) => !a.isNative && !a.amount.isZero)
          .toList();
      debugPrint(
        '[assets] dashboard TOKENS section will render ${visible.length} rows '
        '(filtered out native + zero-balance)',
      );
      setState(() {
        _assets = assets;
        _transactions = results[1] as List<Transaction>;
        _loadingTxs = false;
      });
    } catch (e) {
      debugPrint('[assets] getAssets failed: $e');
      if (!mounted) return;
      setState(() => _loadingTxs = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    final addr = wallet.publicKey ?? '';

    return RefreshIndicator(
      onRefresh: () async {
        wallet.refreshBalances();
        // Re-run on-chain SPL discovery so tokens acquired since the last
        // load (or missed on first launch if the network cache wasn't
        // ready) show up after a pull-to-refresh.
        unawaited(wallet.discoverHoldings());
        await _loadData();
      },
      color: TibaneColors.orange,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Address bar
          InkWell(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: addr));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Address copied'), duration: Duration(seconds: 1)),
              );
            },
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: TibaneColors.darker,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      addr,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(fontSize: 12, color: TibaneColors.textMuted),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.copy, size: 14, color: TibaneColors.textDim),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Total portfolio balance (sum of every asset's USD value) on
          // top, with the native SOL amount underneath as a secondary
          // line.
          Center(
            child: Builder(builder: (context) {
              final totalUsd = _assets.fold<double>(
                0,
                (sum, a) => sum + (a.fiatAmount?.toDouble() ?? 0),
              );
              return Column(
                children: [
                  Text(
                    '\$${totalUsd.toStringAsFixed(2)}',
                    style:
                        Theme.of(context).textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                  ),
                  Text(
                    'TOTAL',
                    style: monoStyle(
                      fontSize: 11,
                      color: TibaneColors.textDim,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${formatSol(wallet.solBalance)} SOL',
                    style: monoStyle(
                      fontSize: 13,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ],
              );
            }),
          ),
          const SizedBox(height: 24),

          // Action buttons — swap entry hidden in UK mode.
          Builder(builder: (context) {
            final isUk = context.watch<UkComplianceService>().isUk;
            return Row(
              children: [
                _ActionButton(
                  icon: Icons.arrow_downward,
                  label: 'Receive',
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const ReceiveScreen())),
                ),
                const SizedBox(width: 12),
                _ActionButton(
                  icon: Icons.arrow_upward,
                  label: 'Send',
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const SendScreen())),
                ),
                if (!isUk) ...[
                  const SizedBox(width: 12),
                  _ActionButton(
                    icon: Icons.swap_horiz,
                    label: 'Swap',
                    onTap: () => _openSwap(context),
                  ),
                ],
              ],
            );
          }),
          const SizedBox(height: 24),

          // Token list — exclude the native asset (it's already shown as
          // the headline balance) and zero-balance rows.
          if (_assets.where((a) => !a.isNative && !a.amount.isZero).isNotEmpty) ...[
            Text('TOKENS', style: monoStyle(fontSize: 11, color: TibaneColors.textDim)),
            const SizedBox(height: 8),
            ..._assets
                .where((a) => !a.isNative && !a.amount.isZero)
                .map((a) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: TibaneCard(
                        padding: const EdgeInsets.all(12),
                        // Tap-to-swap suppressed in UK mode. tokenAddress
                        // is non-null here because the filter above
                        // already excludes native assets; the ?? wsolMint
                        // is just belt-and-braces.
                        onTap: context.read<UkComplianceService>().isUk
                            ? null
                            : () => _openSwap(
                                  context,
                                  inputMint: a.tokenAddress ?? wsolMint,
                                  outputMint: wsolMint,
                                ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    a.symbol.isNotEmpty ? a.symbol : a.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600, fontSize: 14),
                                  ),
                                  if (a.name.isNotEmpty && a.name != a.symbol)
                                    Text(a.name,
                                        style: monoStyle(
                                            fontSize: 11, color: TibaneColors.textMuted)),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  a.amount.toString(),
                                  style: monoStyle(fontSize: 13),
                                ),
                                if (a.fiatAmount != null && !a.fiatAmount!.isZero)
                                  Text(
                                    '\$${a.fiatAmount!.toDouble().toStringAsFixed(2)}',
                                    style: monoStyle(
                                        fontSize: 11, color: TibaneColors.textMuted),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    )),
            const SizedBox(height: 16),
          ],

          // Transaction history
          Text('RECENT ACTIVITY', style: monoStyle(fontSize: 11, color: TibaneColors.textDim)),
          const SizedBox(height: 8),
          if (_loadingTxs)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(color: TibaneColors.orange),
              ),
            )
          else if (_transactions.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('No transactions yet',
                    style: TextStyle(color: TibaneColors.textMuted)),
              ),
            )
          else
            ..._transactions.map((tx) => _TransactionRow(tx: tx, myAddr: addr)),
        ],
      ),
    );
  }

  /// Open the swap screen pre-filled with the requested input/output mints.
  /// Defaults: input = SOL (wSOL), output = ChiefPussy — the dashboard's
  /// headline "Swap" action wants this; the token rows override input to
  /// the tapped mint and output to SOL.
  void _openSwap(
    BuildContext context, {
    String? inputMint,
    String? outputMint,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: TibaneColors.black,
          appBar: AppBar(title: const Text('Swap')),
          body: SwapScreen(
            initialInputMint: inputMint ?? wsolMint,
            initialOutputMint: outputMint ?? chiefPussyMint,
          ),
        ),
      ),
    );
  }

}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: TibaneColors.card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: TibaneColors.border),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: TibaneColors.orange.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: TibaneColors.orange, size: 20),
                ),
                const SizedBox(height: 8),
                Text(label,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TransactionRow extends StatelessWidget {
  final Transaction tx;
  final String myAddr;

  const _TransactionRow({required this.tx, required this.myAddr});

  bool get _isSend => tx.from == myAddr;

  @override
  Widget build(BuildContext context) {
    final counterparty = _isSend ? tx.to : tx.from;
    final amountStr = tx.amount != null ? tx.amount!.toString() : '';
    final fiatStr = tx.fiatAmount != null
        ? '\$${tx.fiatAmount!.toDouble().toStringAsFixed(2)}'
        : null;
    final timeStr = tx.created != null
        ? '${tx.created!.month}/${tx.created!.day} ${tx.created!.hour}:${tx.created!.minute.toString().padLeft(2, '0')}'
        : '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TibaneCard(
        padding: const EdgeInsets.all(12),
        onTap: tx.url != null && tx.url!.isNotEmpty
            ? () => launchUrl(Uri.parse(tx.url!))
            : null,
        child: Row(
          children: [
            Icon(
              _isSend ? Icons.arrow_upward : Icons.arrow_downward,
              size: 18,
              color: _isSend ? TibaneColors.error : TibaneColors.cyan,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isSend ? 'Sent' : 'Received',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  Text(
                    shortenAddress(counterparty),
                    style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${_isSend ? '-' : '+'}$amountStr',
                  style: TextStyle(
                    color: _isSend ? TibaneColors.error : TibaneColors.cyan,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                if (fiatStr != null)
                  Text(fiatStr, style: monoStyle(fontSize: 11, color: TibaneColors.textMuted)),
                if (timeStr.isNotEmpty)
                  Text(timeStr, style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
