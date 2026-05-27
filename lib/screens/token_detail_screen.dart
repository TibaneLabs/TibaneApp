import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../models/staking_pool.dart';
import '../models/token_account.dart';
import '../services/chiefstaker_api.dart';
import '../services/favorites_service.dart';
import '../services/jupiter_service.dart';
import '../services/rpc_service.dart';
import '../services/staker_instructions.dart';
import '../services/uk_compliance_service.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/gradient_button.dart';
import '../widgets/tibane_card.dart';
import 'fee_sharing_screen.dart';
import 'staking/staking_detail_screen.dart';
import 'swap_screen.dart';
import 'wallet/receive_screen.dart';
import 'wallet/send_screen.dart';

/// Read-only analytics view for a single SPL token: metadata, supply,
/// market cap, top holders, recent transactions, optional staking-pool
/// + fee-sharing entry points. Pushed as its own route by
/// [TokenFavoritesScreen] and by deep-link / token-row taps elsewhere
/// in the app, so it owns its [Scaffold] and [AppBar] — no caller
/// wrapping required.
class TokenDetailScreen extends StatefulWidget {
  final String mint;

  const TokenDetailScreen({super.key, required this.mint});

  @override
  State<TokenDetailScreen> createState() => _TokenDetailScreenState();
}

class _TokenDetailScreenState extends State<TokenDetailScreen> {
  final _rpc = RpcService();
  TokenMetadata? _token;
  List<TokenHolder> _holders = [];
  List<Map<String, dynamic>> _transactions = [];
  StakingPool? _stakingPool;
  bool _loading = true;
  String? _error;

  // User's on-chain balance for this token (raw, scaled by decimals).
  // null until the first lookup completes; the Send button stays
  // disabled until we have a positive value to send.
  BigInt? _userBalance;

  @override
  void initState() {
    super.initState();
    _loadToken();
  }

  @override
  void dispose() {
    _rpc.dispose();
    super.dispose();
  }

  Future<void> _loadToken() async {
    if (widget.mint.length < 32) {
      setState(() {
        _error = 'Invalid mint address';
        _loading = false;
      });
      return;
    }
    try {
      final results = await Future.wait([
        _rpc.getAsset(widget.mint),
        _rpc.getTopHolders(widget.mint),
        _rpc.getSignaturesForAddress(widget.mint, limit: 10),
      ]);
      if (!mounted) return;
      setState(() {
        _token = results[0] as TokenMetadata?;
        _holders = results[1] as List<TokenHolder>;
        _transactions = results[2] as List<Map<String, dynamic>>;
        _loading = false;
        if (_token == null) _error = 'Token not found';
      });
      _checkStakingPool();
      _backfillPriceIfMissing();
      _loadUserBalance();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load token: $e';
        _loading = false;
      });
    }
  }

  /// Helius's getAsset only carries a price for a small subset of
  /// SPL tokens. When it doesn't, ask Jupiter's price API — which
  /// covers any actively-traded SPL — so the Market Cap stat can
  /// render for the long tail of tokens too. Idempotent: skips if a
  /// price is already populated or if the screen has unmounted.
  Future<void> _backfillPriceIfMissing() async {
    final token = _token;
    if (token == null || token.pricePerToken != null) return;
    final jupiter = JupiterService();
    try {
      final prices = await jupiter.fetchTokenPrices([widget.mint]);
      if (!mounted) return;
      final price = prices[widget.mint];
      if (price == null || price <= 0) return;
      setState(() {
        _token = _token!.copyWith(pricePerToken: price);
      });
    } finally {
      jupiter.dispose();
    }
  }

  /// AppBar overflow menu — collects Receive / Send / Swap into one
  /// trigger so the actions don't crowd the title row. Send disables
  /// itself when the balance lookup returns zero; Swap is hidden in
  /// UK mode for the same reason it's hidden on other screens.
  Widget _buildActionsMenu(BuildContext context) {
    final token = _token!;
    final isUk = context.watch<UkComplianceService>().isUk;
    final canSend = _userBalance != null && _userBalance! > BigInt.zero;
    return PopupMenuButton<_TokenAction>(
      tooltip: 'Actions',
      icon: const Icon(Icons.more_vert),
      onSelected: (action) {
        switch (action) {
          case _TokenAction.receive:
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const ReceiveScreen()));
          case _TokenAction.send:
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SendScreen(
                  mint: token.mint,
                  symbol: token.symbol,
                  decimals: token.decimals,
                ),
              ),
            );
          case _TokenAction.swap:
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: TibaneColors.black,
                  appBar: AppBar(title: const Text('Swap')),
                  body: SwapScreen(
                    initialInputMint: wsolMint,
                    initialOutputMint: token.mint,
                    initialOutputSymbol: token.symbol,
                    initialOutputName: token.name,
                    initialOutputImageUrl: token.imageUrl,
                    initialOutputDecimals: token.decimals,
                  ),
                ),
              ),
            );
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem<_TokenAction>(
          value: _TokenAction.receive,
          child: _MenuRow(icon: Icons.arrow_downward, label: 'Receive'),
        ),
        PopupMenuItem<_TokenAction>(
          value: _TokenAction.send,
          enabled: canSend,
          child: _MenuRow(
            icon: Icons.arrow_upward,
            label: 'Send',
            dimmed: !canSend,
          ),
        ),
        if (!isUk)
          const PopupMenuItem<_TokenAction>(
            value: _TokenAction.swap,
            child: _MenuRow(icon: Icons.swap_horiz, label: 'Swap'),
          ),
      ],
    );
  }

  /// Fetch the connected wallet's balance for this token so the Send
  /// button can disable itself when there's nothing to send. Native
  /// SOL is the WalletService balance; everything else sums the
  /// matching SPL / Token-2022 accounts.
  Future<void> _loadUserBalance() async {
    if (!mounted) return;
    final wallet = context.read<WalletService>();
    final owner = wallet.publicKey;
    if (owner == null) return;
    try {
      BigInt total;
      if (widget.mint == wsolMint) {
        total = wallet.solBalance;
      } else {
        final results = await Future.wait([
          _rpc.getTokenAccountsByOwner(owner),
          _rpc.getTokenAccountsByOwner(owner, token2022: true),
        ]);
        total = BigInt.zero;
        for (final acc in [...results[0], ...results[1]]) {
          if (acc.mint == widget.mint) total += acc.amount;
        }
      }
      if (!mounted) return;
      setState(() => _userBalance = total);
    } catch (e) {
      if (!mounted) return;
      // Leave _userBalance null so the Send button stays disabled
      // rather than allowing a send the wallet might not cover.
      debugPrint('[token-detail] balance lookup failed: $e');
    }
  }

  /// Resolve the staking pool for this mint from the ChiefStaker API
  /// so it carries the same enrichment (name, symbol, image, decimals,
  /// price, supply, member count) that the pools-list screen has —
  /// otherwise the detail screen we push into renders with a bare
  /// 'Pool' title and missing stats. Falls back to on-chain
  /// deserialization for pools the API doesn't know about, enriching
  /// what we can from the token metadata already loaded above.
  Future<void> _checkStakingPool() async {
    try {
      final api = ChiefStakerApi();
      final pool = await api.getByMint(widget.mint);
      if (!mounted) return;
      if (pool != null) {
        setState(() => _stakingPool = pool);
        return;
      }
      final poolAddr = derivePoolPDA(widget.mint);
      final data = await _rpc.getAccountInfo(poolAddr);
      if (!mounted || data == null) return;
      final onChain = StakingPool.deserialize(poolAddr, data);
      if (onChain == null) return;
      final token = _token;
      if (token != null) {
        onChain.tokenName = token.name;
        onChain.tokenSymbol = token.symbol;
        onChain.tokenImage = token.imageUrl;
        onChain.tokenDecimals = token.decimals;
        onChain.tokenPrice = token.pricePerToken;
        onChain.tokenSupply = token.supply;
      }
      setState(() => _stakingPool = onChain);
    } catch (e) {
      debugPrint('[token-detail] staking pool lookup failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: const Text('Token info'),
        actions: [if (_token != null) _buildActionsMenu(context)],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: TibaneColors.orange),
            )
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.search_off,
                    size: 48,
                    color: TibaneColors.textDim,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: const TextStyle(color: TibaneColors.textMuted),
                  ),
                ],
              ),
            )
          : _token == null
          ? const SizedBox.shrink()
          : _TokenDetails(
              token: _token!,
              holders: _holders,
              transactions: _transactions,
              stakingPool: _stakingPool,
              onRefresh: _loadToken,
            ),
    );
  }
}

class _TokenDetails extends StatelessWidget {
  final TokenMetadata token;
  final List<TokenHolder> holders;
  final List<Map<String, dynamic>> transactions;
  final StakingPool? stakingPool;
  final Future<void> Function() onRefresh;

  const _TokenDetails({
    required this.token,
    required this.holders,
    required this.transactions,
    required this.onRefresh,
    this.stakingPool,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: TibaneColors.orange,
      onRefresh: onRefresh,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TokenHeader(token: token),
            const SizedBox(height: 20),

            _SupplySection(token: token),
            const SizedBox(height: 20),

            if (stakingPool != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TibaneCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StakingDetailScreen(pool: stakingPool!),
                      ),
                    );
                  },
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: TibaneColors.cyan.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.account_balance,
                          size: 16,
                          color: TibaneColors.cyan,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Staking Pool',
                          style: TextStyle(
                            color: TibaneColors.text,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: TibaneColors.cyan.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Active',
                          style: monoStyle(
                            fontSize: 10,
                            color: TibaneColors.cyan,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: TibaneColors.textDim,
                      ),
                    ],
                  ),
                ),
              ),

            if (token.mint.endsWith('pump'))
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: SecondaryButton(
                  label: 'Fee Sharing',
                  icon: Icons.payments,
                  expanded: true,
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => FeeSharingScreen(
                          mint: token.mint,
                          tokenName: token.name,
                        ),
                      ),
                    );
                  },
                ),
              ),

            if (holders.isNotEmpty) ...[
              _HoldersSection(holders: holders, token: token),
              const SizedBox(height: 20),
            ],

            if (transactions.isNotEmpty) ...[
              _TransactionsSection(transactions: transactions),
              const SizedBox(height: 20),
            ],
          ],
        ),
      ),
    );
  }
}

class _TokenHeader extends StatelessWidget {
  final TokenMetadata token;

  const _TokenHeader({required this.token});

  @override
  Widget build(BuildContext context) {
    final favs = context.watch<FavoritesService>();
    final isFav = favs.isFavorite(token.mint);

    return TibaneCard(
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: TibaneColors.darker,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: token.imageUrl != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          token.imageUrl!,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (_, e, s) => const Icon(
                            Icons.token,
                            size: 28,
                            color: TibaneColors.textDim,
                          ),
                        ),
                      )
                    : const Icon(
                        Icons.token,
                        size: 28,
                        color: TibaneColors.textDim,
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      token.name ?? 'Unknown Token',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (token.symbol != null)
                      Text(
                        '\$${token.symbol}',
                        style: const TextStyle(
                          color: TibaneColors.gold,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  GestureDetector(
                    onTap: () => favs.toggle(
                      token.mint,
                      name: token.name,
                      symbol: token.symbol,
                      imageUrl: token.imageUrl,
                    ),
                    child: Icon(
                      isFav ? Icons.star : Icons.star_border,
                      color: isFav ? TibaneColors.gold : TibaneColors.textDim,
                      size: 28,
                    ),
                  ),
                  if (token.pricePerToken != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      '\$${token.pricePerToken!.toStringAsFixed(token.pricePerToken! < 0.01 ? 8 : 4)}',
                      style: const TextStyle(
                        color: TibaneColors.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      'per token',
                      style: monoStyle(
                        fontSize: 10,
                        color: TibaneColors.textDim,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SupplySection extends StatelessWidget {
  final TokenMetadata token;

  const _SupplySection({required this.token});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SUPPLY',
          style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StatCard(
                label: 'Total Supply',
                value: formatTokenAmount(token.supply, token.decimals),
                icon: Icons.pie_chart,
              ),
            ),
            if (token.pricePerToken != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: StatCard(
                  label: 'Market Cap',
                  value: _formatMarketCap(token),
                  valueColor: TibaneColors.gold,
                  icon: Icons.attach_money,
                ),
              ),
            ],
          ],
        ),
        if (token.burned > BigInt.zero) ...[
          const SizedBox(height: 8),
          StatCard(
            label: 'Burned',
            value: formatTokenAmount(token.burned, token.decimals),
            valueColor: TibaneColors.orange,
            icon: Icons.local_fire_department,
          ),
        ],
        const SizedBox(height: 8),
        TibaneCard(
          padding: const EdgeInsets.all(14),
          onTap: () {
            Clipboard.setData(ClipboardData(text: token.mint));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Mint address copied')),
            );
          },
          child: Row(
            children: [
              const Icon(
                Icons.fingerprint,
                size: 16,
                color: TibaneColors.textDim,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  token.mint,
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.copy, size: 14, color: TibaneColors.textDim),
            ],
          ),
        ),
      ],
    );
  }
}

String _formatMarketCap(TokenMetadata token) {
  if (token.pricePerToken == null || token.supply == BigInt.zero) return 'N/A';
  final supplyDouble =
      token.supply.toDouble() / BigInt.from(10).pow(token.decimals).toDouble();
  final mcap = supplyDouble * token.pricePerToken!;
  if (mcap >= 1e9) return '\$${(mcap / 1e9).toStringAsFixed(2)}B';
  if (mcap >= 1e6) return '\$${(mcap / 1e6).toStringAsFixed(2)}M';
  if (mcap >= 1e3) return '\$${(mcap / 1e3).toStringAsFixed(1)}K';
  return '\$${mcap.toStringAsFixed(2)}';
}

class _HoldersSection extends StatelessWidget {
  final List<TokenHolder> holders;
  final TokenMetadata token;

  const _HoldersSection({required this.holders, required this.token});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TOP HOLDERS',
          style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 12),
        TibaneCard(
          child: Column(
            children: [
              for (var i = 0; i < holders.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: TibaneColors.border),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        child: Text(
                          '#${i + 1}',
                          style: monoStyle(
                            fontSize: 11,
                            color: i < 3
                                ? TibaneColors.gold
                                : TibaneColors.textDim,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          shortenAddress(holders[i].address, chars: 6),
                          style: monoStyle(
                            fontSize: 12,
                            color: TibaneColors.textMuted,
                          ),
                        ),
                      ),
                      Text(
                        '${holders[i].percentage.toStringAsFixed(2)}%',
                        style: monoStyle(
                          fontSize: 12,
                          color: holders[i].percentage > 5
                              ? TibaneColors.orange
                              : TibaneColors.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _TransactionsSection extends StatelessWidget {
  final List<Map<String, dynamic>> transactions;

  const _TransactionsSection({required this.transactions});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'RECENT TRANSACTIONS',
          style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 12),
        TibaneCard(
          child: Column(
            children: [
              for (var i = 0; i < transactions.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: TibaneColors.border),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        transactions[i]['err'] != null
                            ? Icons.error
                            : Icons.check_circle,
                        size: 14,
                        color: transactions[i]['err'] != null
                            ? TibaneColors.error
                            : TibaneColors.cyan,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          shortenAddress(
                            transactions[i]['signature'] as String,
                            chars: 8,
                          ),
                          style: monoStyle(fontSize: 12),
                        ),
                      ),
                      if (transactions[i]['blockTime'] != null)
                        Text(
                          _formatTime(transactions[i]['blockTime'] as int),
                          style: monoStyle(
                            fontSize: 10,
                            color: TibaneColors.textDim,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _formatTime(int blockTime) {
    final dt = DateTime.fromMillisecondsSinceEpoch(blockTime * 1000);
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}';
  }
}

/// Actions surfaced in the AppBar overflow menu.
enum _TokenAction { receive, send, swap }

/// Single row inside the overflow menu: icon + label. The colour
/// drops to `textDim` when [dimmed] is true so a disabled Send item
/// reads as obviously not-tappable (Flutter's default disabled menu
/// item is barely greyer than the enabled state on a dark theme).
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool dimmed;

  const _MenuRow({
    required this.icon,
    required this.label,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = dimmed ? TibaneColors.textDim : TibaneColors.text;
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}
