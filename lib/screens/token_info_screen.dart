import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../models/staking_pool.dart';
import '../models/token_account.dart';
import '../services/favorites_service.dart';
import '../services/rpc_service.dart';
import '../services/staker_instructions.dart';
import '../theme/tibane_theme.dart';
import '../widgets/gradient_button.dart';
import '../widgets/tibane_card.dart';
import 'fee_sharing_screen.dart';
import 'staking/staking_detail_screen.dart';

class TokenInfoScreen extends StatefulWidget {
  final String? initialMint;

  const TokenInfoScreen({super.key, this.initialMint});

  @override
  State<TokenInfoScreen> createState() => _TokenInfoScreenState();
}

class _TokenInfoScreenState extends State<TokenInfoScreen> {
  final _rpc = RpcService();
  final _searchController = TextEditingController();
  TokenMetadata? _token;
  List<TokenHolder> _holders = [];
  List<Map<String, dynamic>> _transactions = [];
  StakingPool? _stakingPool;
  bool _loading = false;
  String? _error;
  bool _showingDetail = false;

  @override
  void initState() {
    super.initState();
    final mint = widget.initialMint;
    if (mint != null && mint.isNotEmpty) {
      _searchController.text = mint;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadToken(mint));
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _rpc.dispose();
    super.dispose();
  }

  Future<void> _loadToken(String mint) async {
    if (mint.length < 32) return;

    setState(() {
      _loading = true;
      _error = null;
      _token = null;
      _holders = [];
      _transactions = [];
      _stakingPool = null;
      _showingDetail = true;
    });

    try {
      final results = await Future.wait([
        _rpc.getAsset(mint),
        _rpc.getTopHolders(mint),
        _rpc.getSignaturesForAddress(mint, limit: 10),
      ]);

      setState(() {
        _token = results[0] as TokenMetadata?;
        _holders = results[1] as List<TokenHolder>;
        _transactions = results[2] as List<Map<String, dynamic>>;
        _loading = false;
        if (_token == null) _error = 'Token not found';
      });
      _checkStakingPool(mint);
    } catch (e) {
      setState(() {
        _error = 'Failed to load token: $e';
        _loading = false;
      });
    }
  }

  Future<void> _checkStakingPool(String mint) async {
    try {
      final poolAddr = derivePoolPDA(mint);
      final data = await _rpc.getAccountInfo(poolAddr);
      if (data != null && mounted) {
        final pool = StakingPool.deserialize(poolAddr, data);
        if (pool != null) {
          setState(() => _stakingPool = pool);
        }
      }
    } catch (_) {}
  }

  void _goBack() {
    setState(() {
      _showingDetail = false;
      _token = null;
      _error = null;
      _searchController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_showingDetail) {
      return _buildDetailView();
    }
    return _buildFavoritesView();
  }

  Widget _buildFavoritesView() {
    final favs = context.watch<FavoritesService>();

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: TibaneColors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.analytics_outlined, color: TibaneColors.orange, size: 24),
              ),
              const SizedBox(width: 12),
              Text('Tokens', style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            controller: _searchController,
            onSubmitted: _loadToken,
            decoration: InputDecoration(
              hintText: 'Search by mint address...',
              prefixIcon: const Icon(Icons.search, size: 20, color: TibaneColors.textDim),
              suffixIcon: IconButton(
                onPressed: () => _loadToken(_searchController.text.trim()),
                icon: const Icon(Icons.arrow_forward, size: 18),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        // Favorites list
        Expanded(
          child: favs.favorites.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star_border, size: 48, color: TibaneColors.textDim),
                      const SizedBox(height: 12),
                      Text(
                        'No favorite tokens yet',
                        style: TextStyle(color: TibaneColors.textMuted),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Search for a token and tap the star to add it',
                        style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: favs.favorites.length,
                  itemBuilder: (context, index) {
                    final fav = favs.favorites[index];
                    return _FavoriteTokenTile(
                      token: fav,
                      onTap: () => _loadToken(fav.mint),
                      onRemove: () => favs.toggle(fav.mint),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDetailView() {
    return Column(
      children: [
        // Header with back button
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
          child: Row(
            children: [
              IconButton(
                onPressed: _goBack,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              Text('Token Info', style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Content
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: TibaneColors.orange))
              : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.search_off, size: 48, color: TibaneColors.textDim),
                          const SizedBox(height: 16),
                          Text(_error!, style: const TextStyle(color: TibaneColors.textMuted)),
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
                        ),
        ),
      ],
    );
  }
}

class _FavoriteTokenTile extends StatelessWidget {
  final FavoriteToken token;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _FavoriteTokenTile({
    required this.token,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TibaneCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // Token image
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: TibaneColors.darker,
                borderRadius: BorderRadius.circular(10),
              ),
              child: token.imageUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        token.imageUrl!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorBuilder: (_, e, s) =>
                            const Icon(Icons.token, size: 20, color: TibaneColors.textDim),
                      ),
                    )
                  : const Icon(Icons.token, size: 20, color: TibaneColors.textDim),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    token.name ?? 'Unknown',
                    style: const TextStyle(
                      color: TibaneColors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (token.symbol != null)
                    Text(
                      '\$${token.symbol}',
                      style: monoStyle(fontSize: 11, color: TibaneColors.gold),
                    ),
                ],
              ),
            ),
            Text(
              shortenAddress(token.mint),
              style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onRemove,
              child: const Icon(Icons.star, color: TibaneColors.gold, size: 22),
            ),
          ],
        ),
      ),
    );
  }
}

class _TokenDetails extends StatelessWidget {
  final TokenMetadata token;
  final List<TokenHolder> holders;
  final List<Map<String, dynamic>> transactions;
  final StakingPool? stakingPool;

  const _TokenDetails({
    required this.token,
    required this.holders,
    required this.transactions,
    this.stakingPool,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Token header
          _TokenHeader(token: token),
          const SizedBox(height: 20),

          // Supply info
          _SupplySection(token: token),
          const SizedBox(height: 20),

          // Staking pool badge
          if (stakingPool != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TibaneCard(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                      child: const Icon(Icons.account_balance, size: 16, color: TibaneColors.cyan),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Staking Pool', style: TextStyle(color: TibaneColors.text, fontWeight: FontWeight.w500)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: TibaneColors.cyan.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('Active', style: monoStyle(fontSize: 10, color: TibaneColors.cyan)),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 16, color: TibaneColors.textDim),
                  ],
                ),
              ),
            ),

          // Fee sharing button (for pump.fun tokens)
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

          // Top holders
          if (holders.isNotEmpty) ...[
            _HoldersSection(holders: holders, token: token),
            const SizedBox(height: 20),
          ],

          // Recent transactions
          if (transactions.isNotEmpty) ...[
            _TransactionsSection(transactions: transactions),
            const SizedBox(height: 20),
          ],
        ],
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
              // Token image
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
                    : const Icon(Icons.token, size: 28, color: TibaneColors.textDim),
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
                      style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
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
        Text('SUPPLY', style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
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
            const SizedBox(width: 8),
            if (token.pricePerToken != null)
              Expanded(
                child: StatCard(
                  label: 'Market Cap',
                  value: _formatMarketCap(token),
                  valueColor: TibaneColors.gold,
                  icon: Icons.attach_money,
                ),
              )
            else
              Expanded(
                child: StatCard(
                  label: 'Decimals',
                  value: '${token.decimals}',
                  icon: Icons.code,
                ),
              ),
          ],
        ),
        if (token.burned > BigInt.zero) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: StatCard(
                  label: 'Burned',
                  value: formatTokenAmount(token.burned, token.decimals),
                  valueColor: TibaneColors.orange,
                  icon: Icons.local_fire_department,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StatCard(
                  label: 'Decimals',
                  value: '${token.decimals}',
                  icon: Icons.code,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        // Mint address
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
              const Icon(Icons.fingerprint, size: 16, color: TibaneColors.textDim),
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
  final supplyDouble = token.supply.toDouble() / BigInt.from(10).pow(token.decimals).toDouble();
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
        Text('TOP HOLDERS', style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
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
                            color: i < 3 ? TibaneColors.gold : TibaneColors.textDim,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          shortenAddress(holders[i].address, chars: 6),
                          style: monoStyle(fontSize: 12, color: TibaneColors.textMuted),
                        ),
                      ),
                      Text(
                        '${holders[i].percentage.toStringAsFixed(2)}%',
                        style: monoStyle(
                          fontSize: 12,
                          color: holders[i].percentage > 5 ? TibaneColors.orange : TibaneColors.text,
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
        Text('RECENT TRANSACTIONS', style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
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
                        transactions[i]['err'] != null ? Icons.error : Icons.check_circle,
                        size: 14,
                        color: transactions[i]['err'] != null ? TibaneColors.error : TibaneColors.cyan,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          shortenAddress(transactions[i]['signature'] as String, chars: 8),
                          style: monoStyle(fontSize: 12),
                        ),
                      ),
                      if (transactions[i]['blockTime'] != null)
                        Text(
                          _formatTime(transactions[i]['blockTime'] as int),
                          style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
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
