import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show Asset, Transaction, TxHistoryUpdatedEvent;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../constants/solana_constants.dart';
import '../../services/jupiter_service.dart';
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
  List<TokenHolding> _holdings = [];
  List<Transaction> _transactions = [];
  bool _loadingTxs = true;
  bool _kickedHistoryBackfill = false;
  StreamSubscription<TxHistoryUpdatedEvent>? _txHistorySub;
  WalletService? _walletRef;
  final JupiterService _jupiter = JupiterService();

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
      debugPrint('[txhist] subscribed to txHistoryUpdates');
      _txHistorySub = client.txHistoryUpdates.listen((e) {
        debugPrint(
          '[txhist] event: account=${e.accountId} network=${e.networkId} '
          'count=${e.count}',
        );
        if (!mounted) return;
        _loadData();
      });
    } catch (e) {
      debugPrint('[txhist] txHistoryUpdates subscribe failed: $e');
    }
  }

  @override
  void dispose() {
    _txHistorySub?.cancel();
    _walletRef?.swapCommittedTick.removeListener(_onTxCommitted);
    _jupiter.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final wallet = context.read<WalletService>();
    final lw = wallet.libwallet;
    final addr = wallet.publicKey;
    // libwallet supplies SOL's fiat conversion and the transaction history;
    // the SPL-token list comes straight from on-chain RPC so any non-zero
    // balance shows up regardless of whether libwallet has tracked the
    // mint yet.
    try {
      final results = await Future.wait([
        lw.getAssets(),
        lw.getTransactions(limit: 50),
        if (addr != null)
          _jupiter.fetchHoldings(addr, excludeMint: wsolMint)
        else
          Future.value(const <TokenHolding>[]),
      ]);
      if (!mounted) return;
      final assets = results[0] as List<Asset>;
      final txs = results[1] as List<Transaction>;
      final holdings = results[2] as List<TokenHolding>;
      debugPrint(
        '[dashboard] _loadData: addr=$addr account=${lw.accountId} '
        'network=${lw.currentNetwork?.id} '
        'assets=${assets.length} holdings=${holdings.length} '
        'txs=${txs.length}',
      );
      setState(() {
        _assets = assets;
        _transactions = txs;
        _holdings = holdings;
        _loadingTxs = false;
      });
      // First load came back with an empty tx list — libwallet's
      // background backfill may have silently failed on env init. Re-fire
      // it once per dashboard mount; results land via txHistoryUpdates.
      if (txs.isEmpty && !_kickedHistoryBackfill) {
        _kickedHistoryBackfill = true;
        debugPrint('[dashboard] tx list empty on first load — kicking backfill');
        unawaited(lw.kickHistoryBackfill());
      }
    } catch (e) {
      debugPrint('[dashboard] _loadData failed: $e');
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

          // Total portfolio balance (SOL fiat from libwallet + sum of
          // every on-chain SPL holding's USD value) on top, with the
          // native SOL amount underneath as a secondary line.
          Center(
            child: Builder(builder: (context) {
              final solFiat = _assets
                  .where((a) => a.isNative)
                  .fold<double>(
                    0,
                    (sum, a) => sum + (a.fiatAmount?.toDouble() ?? 0),
                  );
              final tokensFiat = _holdings.fold<double>(
                0,
                (sum, h) => sum + (h.valueUsd ?? 0),
              );
              final totalUsd = solFiat + tokensFiat;
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

          // Token list — every non-zero on-chain SPL holding (legacy +
          // Token-2022), scanned directly via RPC so a token appears the
          // moment its balance lands, without waiting on libwallet's
          // auto-discovery to register the mint.
          if (_holdings.isNotEmpty) ...[
            Text('TOKENS', style: monoStyle(fontSize: 11, color: TibaneColors.textDim)),
            const SizedBox(height: 8),
            ..._holdings.map((h) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: TibaneCard(
                    padding: const EdgeInsets.all(12),
                    onTap: context.read<UkComplianceService>().isUk
                        ? null
                        : () => _openSwap(
                              context,
                              inputMint: h.mint,
                              outputMint: wsolMint,
                            ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                h.symbol.isNotEmpty ? h.symbol : h.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 14),
                              ),
                              if (h.name.isNotEmpty && h.name != h.symbol)
                                Text(h.name,
                                    style: monoStyle(
                                        fontSize: 11, color: TibaneColors.textMuted)),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              formatTokenAmount(h.balance, h.decimals, displayDecimals: 4),
                              style: monoStyle(fontSize: 13),
                            ),
                            if (h.valueUsd != null)
                              Text(
                                '\$${h.valueUsd!.toStringAsFixed(2)}',
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
