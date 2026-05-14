import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../constants/solana_constants.dart';
import '../../models/staking_pool.dart';
import '../../services/chiefstaker_api.dart';
import '../../services/favorites_service.dart';
import '../../services/uk_compliance_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import 'staking_detail_screen.dart';

class StakingPoolsScreen extends StatefulWidget {
  const StakingPoolsScreen({super.key});

  @override
  State<StakingPoolsScreen> createState() => _StakingPoolsScreenState();
}

class _StakingPoolsScreenState extends State<StakingPoolsScreen> {
  final _api = ChiefStakerApi();
  final _searchController = TextEditingController();
  List<StakingPool> _pools = [];
  bool _loading = true;
  String? _error;
  String _sortBy = 'members';

  @override
  void initState() {
    super.initState();
    _loadPools();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPools() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final pools = await _api.listPools();
      if (!mounted) return;
      setState(() {
        _pools = pools;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load pools: $e';
        _loading = false;
      });
    }
  }

  List<StakingPool> get _filteredPools {
    var pools = _pools.toList();

    // Search filter
    final query = _searchController.text.toLowerCase();
    if (query.isNotEmpty) {
      pools = pools.where((p) {
        return (p.tokenName?.toLowerCase().contains(query) ?? false) ||
            (p.tokenSymbol?.toLowerCase().contains(query) ?? false) ||
            p.mint.toLowerCase().contains(query);
      }).toList();
    }

    // Sort
    switch (_sortBy) {
      case 'staked':
        pools.sort((a, b) => b.totalStaked.compareTo(a.totalStaked));
      case 'rewards':
        pools.sort((a, b) => b.rewardBalance.compareTo(a.rewardBalance));
      case 'age':
        pools.sort((a, b) => a.initialBaseTime.compareTo(b.initialBaseTime));
      case 'mcap':
        pools.sort((a, b) => (b.marketCap ?? -1).compareTo(a.marketCap ?? -1));
      case 'name':
        pools.sort((a, b) => (a.tokenName ?? '').compareTo(b.tokenName ?? ''));
      default: // members
        pools.sort((a, b) => b.memberCount.compareTo(a.memberCount));
    }

    return pools;
  }

  @override
  Widget build(BuildContext context) {
    if (context.watch<UkComplianceService>().isUk) {
      return const _StakingUnavailableInRegion();
    }
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
                child: const Icon(Icons.account_balance, color: TibaneColors.orange, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Staking Pools', style: Theme.of(context).textTheme.titleLarge),
                    Text(
                      '${_pools.length} pools',
                      style: monoStyle(fontSize: 12, color: TibaneColors.textMuted),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _loading ? null : _loadPools,
                icon: const Icon(Icons.refresh, size: 20),
                color: TibaneColors.textMuted,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Search
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search by name, symbol, or mint...',
              prefixIcon: const Icon(Icons.search, size: 20, color: TibaneColors.textDim),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.clear, size: 18),
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Sort chips
        SizedBox(
          height: 32,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              _SortChip(label: 'Members', value: 'members', current: _sortBy, onTap: (v) => setState(() => _sortBy = v)),
              const SizedBox(width: 8),
              _SortChip(label: 'MCap', value: 'mcap', current: _sortBy, onTap: (v) => setState(() => _sortBy = v)),
              const SizedBox(width: 8),
              _SortChip(label: 'Staked', value: 'staked', current: _sortBy, onTap: (v) => setState(() => _sortBy = v)),
              const SizedBox(width: 8),
              _SortChip(label: 'Rewards', value: 'rewards', current: _sortBy, onTap: (v) => setState(() => _sortBy = v)),
              const SizedBox(width: 8),
              _SortChip(label: 'Age', value: 'age', current: _sortBy, onTap: (v) => setState(() => _sortBy = v)),
              const SizedBox(width: 8),
              _SortChip(label: 'Name', value: 'name', current: _sortBy, onTap: (v) => setState(() => _sortBy = v)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Pool list
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: TibaneColors.orange))
              : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, size: 48, color: TibaneColors.error),
                          const SizedBox(height: 16),
                          Text(_error!, style: const TextStyle(color: TibaneColors.textMuted)),
                          const SizedBox(height: 16),
                          OutlinedButton(onPressed: _loadPools, child: const Text('Retry')),
                        ],
                      ),
                    )
                  : _filteredPools.isEmpty
                      ? Center(
                          child: Text(
                            _searchController.text.isNotEmpty
                                ? 'No pools match your search'
                                : 'No staking pools found',
                            style: const TextStyle(color: TibaneColors.textMuted),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _loadPools,
                          color: TibaneColors.orange,
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: _filteredPools.length,
                            itemBuilder: (context, index) {
                              final pool = _filteredPools[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _PoolCard(
                                  pool: pool,
                                  onTap: () => _navigateToPool(pool),
                                ),
                              );
                            },
                          ),
                        ),
        ),
      ],
    );
  }

  void _navigateToPool(StakingPool pool) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StakingDetailScreen(pool: pool),
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  final String label;
  final String value;
  final String current;
  final void Function(String) onTap;

  const _SortChip({
    required this.label,
    required this.value,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selected = value == current;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? TibaneColors.orange.withValues(alpha: 0.15) : TibaneColors.darker,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? TibaneColors.orange.withValues(alpha: 0.3) : TibaneColors.border,
          ),
        ),
        child: Text(
          label,
          style: monoStyle(
            fontSize: 11,
            color: selected ? TibaneColors.orange : TibaneColors.textMuted,
          ),
        ),
      ),
    );
  }
}

String _formatMcap(double? mcap) {
  if (mcap == null) return 'N/A';
  if (mcap >= 1e9) return '\$${(mcap / 1e9).toStringAsFixed(2)}B';
  if (mcap >= 1e6) return '\$${(mcap / 1e6).toStringAsFixed(2)}M';
  if (mcap >= 1e3) return '\$${(mcap / 1e3).toStringAsFixed(1)}K';
  return '\$${mcap.toStringAsFixed(2)}';
}

class _PoolCard extends StatelessWidget {
  final StakingPool pool;
  final VoidCallback onTap;

  const _PoolCard({required this.pool, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TibaneCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Token image
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: TibaneColors.darker,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: pool.tokenImage != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          pool.tokenImage!,
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                          errorBuilder: (_, e, s) => const Icon(
                            Icons.token,
                            size: 20,
                            color: TibaneColors.textDim,
                          ),
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
                      pool.tokenName ?? pool.tokenSymbol ?? 'Unknown',
                      style: const TextStyle(
                        color: TibaneColors.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      pool.tokenSymbol ?? shortenAddress(pool.mint),
                      style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                    ),
                  ],
                ),
              ),
              Builder(builder: (context) {
                final favs = context.watch<FavoritesService>();
                final isFav = favs.isFavorite(pool.mint);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    GestureDetector(
                      onTap: () => favs.toggle(
                        pool.mint,
                        name: pool.tokenName,
                        symbol: pool.tokenSymbol,
                        imageUrl: pool.tokenImage,
                      ),
                      child: Icon(
                        isFav ? Icons.star : Icons.star_border,
                        color: isFav ? TibaneColors.gold : TibaneColors.textDim,
                        size: 22,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: TibaneColors.cyan.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'tau ${pool.tauFormatted}',
                        style: monoStyle(fontSize: 10, color: TibaneColors.cyan),
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
          const SizedBox(height: 14),
          // Stats row
          Row(
            children: [
              _PoolStat(
                label: 'MCap',
                value: _formatMcap(pool.marketCap),
                valueColor: pool.marketCap != null ? TibaneColors.gold : null,
              ),
              _PoolStat(
                label: 'Staked',
                value: formatTokenAmount(pool.totalStaked, pool.tokenDecimals),
              ),
              _PoolStat(
                label: 'Rewards',
                value: '${formatSol(pool.rewardBalance, decimals: 2)} SOL',
                valueColor: TibaneColors.gold,
              ),
              _PoolStat(
                label: 'Members',
                value: '${pool.memberCount}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PoolStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _PoolStat({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: monoStyle(fontSize: 9, color: TibaneColors.textDim),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? TibaneColors.text,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// Region-block screen for UK users in place of the staking pools list.
/// Tibane's staking program is a financial promotion under FCA PS23/6,
/// which we are not authorised to make to UK consumers.
class _StakingUnavailableInRegion extends StatelessWidget {
  const _StakingUnavailableInRegion();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.public_off,
              color: TibaneColors.textDim,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              'Staking not available in your region',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Tibane does not offer in-app staking in the United Kingdom. '
              'You can still use the in-app browser to access third-party '
              'services directly.',
              style: TextStyle(color: TibaneColors.textMuted, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
