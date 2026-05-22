import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../constants/solana_constants.dart';
import '../../models/staking_pool.dart';
import '../../services/rpc_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';

class StakingMembersScreen extends StatefulWidget {
  final StakingPool pool;

  const StakingMembersScreen({super.key, required this.pool});

  @override
  State<StakingMembersScreen> createState() => _StakingMembersScreenState();
}

enum _SortField { rank, amount, weight, pending, immature, stakedSince }

class _StakingMembersScreenState extends State<StakingMembersScreen> {
  final _rpc = RpcService();
  List<_MemberRow>? _members;
  bool _loading = false;
  String? _error;
  _SortField _sortField = _SortField.amount;
  bool _sortAsc = false;

  StakingPool get pool => widget.pool;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  @override
  void dispose() {
    _rpc.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final stakes = await _rpc.getUserStakesForPool(pool.address);

      final members = stakes.map((s) {
        final weight = calculateWeightPercent(
          pool.tauSeconds,
          pool.baseTime,
          s.stake.expStartFactor,
        );
        final pending = estimatePendingRewards(pool, s.stake);
        final immature = estimateImmatureRewards(pool, s.stake);
        return _MemberRow(
          owner: s.stake.owner,
          amount: s.stake.amount,
          weightPercent: weight,
          pending: pending,
          immature: immature,
          stakeTime: s.stake.stakeTime,
        );
      }).toList();

      // Sort by amount descending initially
      members.sort((a, b) => b.amount.compareTo(a.amount));

      setState(() {
        _members = members;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load members: $e';
        _loading = false;
      });
    }
  }

  void _sort(_SortField field) {
    if (_sortField == field) {
      _sortAsc = !_sortAsc;
    } else {
      _sortField = field;
      _sortAsc = false;
    }
    _members?.sort((a, b) {
      int cmp;
      switch (_sortField) {
        case _SortField.rank:
        case _SortField.amount:
          cmp = a.amount.compareTo(b.amount);
        case _SortField.weight:
          cmp = a.weightPercent.compareTo(b.weightPercent);
        case _SortField.pending:
          cmp = a.pending.compareTo(b.pending);
        case _SortField.immature:
          cmp = a.immature.compareTo(b.immature);
        case _SortField.stakedSince:
          cmp = a.stakeTime.compareTo(b.stakeTime);
      }
      return _sortAsc ? cmp : -cmp;
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        backgroundColor: TibaneColors.black,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Row(
          children: [
            if (pool.tokenImage != null)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    pool.tokenImage!,
                    width: 24,
                    height: 24,
                    errorBuilder: (_, e, s) => const SizedBox.shrink(),
                  ),
                ),
              ),
            Expanded(
              child: Text(
                '${pool.tokenSymbol ?? 'Pool'} Members',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadMembers,
            icon: const Icon(Icons.refresh, size: 20),
            color: TibaneColors.textMuted,
          ),
        ],
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
                    Icons.error_outline,
                    size: 48,
                    color: TibaneColors.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: const TextStyle(color: TibaneColors.textMuted),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: _loadMembers,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    final members = _members;
    if (members == null || members.isEmpty) {
      return const Center(
        child: Text(
          'No members found',
          style: TextStyle(color: TibaneColors.textMuted),
        ),
      );
    }

    return Column(
      children: [
        // Pool summary
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Row(
            children: [
              Expanded(
                child: StatCard(
                  label: 'Total Staked',
                  value: formatTokenAmount(
                    pool.totalStaked,
                    pool.tokenDecimals,
                  ),
                  icon: Icons.lock,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StatCard(
                  label: 'Members',
                  value: '${members.length}',
                  icon: Icons.people,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StatCard(
                  label: 'Tau',
                  value: pool.tauFormatted,
                  icon: Icons.timer,
                ),
              ),
            ],
          ),
        ),
        // Sort header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              _sortChip('#', _SortField.rank, width: 32),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Address',
                  style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
                ),
              ),
              _sortChip('Amount', _SortField.amount),
              _sortChip('Wt%', _SortField.weight),
              _sortChip('Pending', _SortField.pending),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // Members list
        Expanded(
          child: RefreshIndicator(
            color: TibaneColors.orange,
            onRefresh: _loadMembers,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: members.length,
              itemBuilder: (context, index) {
                final m = members[index];
                return _MemberTile(
                  rank: index + 1,
                  member: m,
                  pool: pool,
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: m.owner));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Address copied')),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _sortChip(String label, _SortField field, {double? width}) {
    final isActive = _sortField == field;
    return GestureDetector(
      onTap: () => _sort(field),
      child: SizedBox(
        width: width ?? 64,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: monoStyle(
                fontSize: 10,
                color: isActive ? TibaneColors.orange : TibaneColors.textDim,
              ),
            ),
            if (isActive)
              Icon(
                _sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
                size: 10,
                color: TibaneColors.orange,
              ),
          ],
        ),
      ),
    );
  }
}

class _MemberRow {
  final String owner;
  final BigInt amount;
  final double weightPercent;
  final BigInt pending;
  final BigInt immature;
  final BigInt stakeTime;

  _MemberRow({
    required this.owner,
    required this.amount,
    required this.weightPercent,
    required this.pending,
    required this.immature,
    required this.stakeTime,
  });
}

class _MemberTile extends StatelessWidget {
  final int rank;
  final _MemberRow member;
  final StakingPool pool;
  final VoidCallback onTap;

  const _MemberTile({
    required this.rank,
    required this.member,
    required this.pool,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: TibaneCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '$rank',
                style: monoStyle(
                  fontSize: 11,
                  color: rank <= 3 ? TibaneColors.gold : TibaneColors.textDim,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shortenAddress(member.owner, chars: 4),
                    style: monoStyle(
                      fontSize: 12,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        formatTokenAmount(member.amount, pool.tokenDecimals),
                        style: monoStyle(
                          fontSize: 10,
                          color: TibaneColors.text,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatStakeAge(member.stakeTime),
                        style: monoStyle(
                          fontSize: 9,
                          color: TibaneColors.textDim,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${member.weightPercent.toStringAsFixed(1)}%',
                  style: monoStyle(
                    fontSize: 11,
                    color: member.weightPercent > 90
                        ? TibaneColors.cyan
                        : member.weightPercent > 50
                        ? TibaneColors.gold
                        : TibaneColors.orange,
                  ),
                ),
                if (member.pending > BigInt.zero)
                  Text(
                    '${formatSol(member.pending, decimals: 4)} SOL',
                    style: monoStyle(fontSize: 9, color: TibaneColors.gold),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatStakeAge(BigInt stakeTimestamp) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final age = now - stakeTimestamp.toInt();
    if (age < 3600) return '${age ~/ 60}m';
    if (age < 86400) return '${age ~/ 3600}h';
    return '${age ~/ 86400}d';
  }
}
