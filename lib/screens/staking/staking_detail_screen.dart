import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../constants/solana_constants.dart';
import '../../models/staking_pool.dart';
import '../../services/rpc_service.dart';
import '../../services/solana_common.dart';
import '../../services/staker_instructions.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/gradient_button.dart';
import '../../widgets/tibane_card.dart';
import '../swap_screen.dart';
import '../wallet/inapp_unlock_screen.dart';
import 'staking_members_screen.dart';

class StakingDetailScreen extends StatefulWidget {
  final StakingPool pool;

  const StakingDetailScreen({super.key, required this.pool});

  @override
  State<StakingDetailScreen> createState() => _StakingDetailScreenState();
}

class _StakingDetailScreenState extends State<StakingDetailScreen> {
  final _rpc = RpcService();
  final _stakeController = TextEditingController();
  final _unstakeController = TextEditingController();
  final _beneficiaryController = TextEditingController();
  UserStake? _userStake;
  BigInt _walletBalance = BigInt.zero;
  bool _loadingStake = false;
  bool _staking = false;
  String? _error;
  late StakingPool _pool;

  StakingPool get pool => _pool;

  @override
  void initState() {
    super.initState();
    _pool = widget.pool;
    _loadUserStake();
  }

  @override
  void dispose() {
    _stakeController.dispose();
    _unstakeController.dispose();
    _beneficiaryController.dispose();
    _rpc.dispose();
    super.dispose();
  }

  Future<void> _loadUserStake() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;

    setState(() => _loadingStake = true);

    try {
      final results = await Future.wait([
        _rpc.getUserStake(pool.address, wallet.publicKey!),
        _fetchWalletBalance(wallet.publicKey!),
        _rpc.getStakingPool(pool.address),
      ]);
      setState(() {
        _userStake = results[0] as UserStake?;
        _walletBalance = results[1] as BigInt;
        final refreshedPool = results[2] as StakingPool?;
        if (refreshedPool != null) _pool = refreshedPool;
        _loadingStake = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load stake: $e';
        _loadingStake = false;
      });
    }
  }

  BigInt get _pendingRewards {
    if (_userStake == null) return BigInt.zero;
    return estimatePendingRewards(pool, _userStake!);
  }

  double get _weightPercent {
    if (_userStake == null) return 0;
    return calculateWeightPercent(
      pool.tauSeconds,
      pool.baseTime,
      _userStake!.expStartFactor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();

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
            Text(pool.tokenName ?? pool.tokenSymbol ?? 'Pool'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Swap SOL → ${pool.tokenSymbol ?? "token"}',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: TibaneColors.black,
                  appBar: AppBar(title: const Text('Swap')),
                  body: SwapScreen(
                    initialInputMint: wsolMint,
                    initialOutputMint: pool.mint,
                    initialOutputSymbol: pool.tokenSymbol,
                    initialOutputName: pool.tokenName,
                    initialOutputImageUrl: pool.tokenImage,
                    initialOutputDecimals: pool.tokenDecimals,
                  ),
                ),
              ),
            ),
            icon: const Icon(Icons.swap_horiz, size: 20),
          ),
          IconButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pool.address));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Pool address copied')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            tooltip: 'Copy pool address',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Error
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: TibaneColors.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: TibaneColors.error.withValues(alpha: 0.2)),
                ),
                child: Text(_error!, style: const TextStyle(color: TibaneColors.error, fontSize: 13)),
              ),
              const SizedBox(height: 16),
            ],
            // Pool stats
            _PoolStatsSection(pool: pool),
            const SizedBox(height: 20),

            // User stake section
            if (wallet.isConnected) ...[
              _UserStakeSection(
                pool: pool,
                userStake: _userStake,
                loading: _loadingStake,
                pendingRewards: _pendingRewards,
                weightPercent: _weightPercent,
              ),
              const SizedBox(height: 20),

              // Weight milestones
              if (_userStake != null && _userStake!.amount > BigInt.zero) ...[
                _WeightMilestonesSection(pool: pool, weightPercent: _weightPercent),
                const SizedBox(height: 20),

                // Actions
                _ActionsSection(
                  pool: pool,
                  userStake: _userStake!,
                  pendingRewards: _pendingRewards,
                  unstakeController: _unstakeController,
                  onAction: (action, {BigInt? amount}) => _handleAction(action, unstakeAmount: amount),
                ),
                const SizedBox(height: 20),
              ],

              // Close stake account (empty stake, no pending unstake)
              if (_userStake != null &&
                  _userStake!.amount == BigInt.zero &&
                  !_userStake!.hasUnstakeRequest) ...[
                SecondaryButton(
                  label: 'Close Stake Account',
                  icon: Icons.delete_outline,
                  expanded: true,
                  onPressed: _staking ? null : () => _handleAction('closeAccount'),
                ),
                const SizedBox(height: 20),
              ],

              // Stake input
              _StakeInputSection(
                controller: _stakeController,
                beneficiaryController: _beneficiaryController,
                pool: pool,
                walletBalance: _walletBalance,
                staking: _staking,
                onStake: () => _handleAction('stake'),
              ),
            ] else
              TibaneCard(
                child: Column(
                  children: [
                    const Icon(Icons.account_balance_wallet_outlined, size: 40, color: TibaneColors.textDim),
                    const SizedBox(height: 12),
                    Text(
                      'Connect your wallet to stake',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: TibaneColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 20),

            // View Members button
            SecondaryButton(
              label: 'View Members',
              icon: Icons.people,
              expanded: true,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => StakingMembersScreen(pool: pool),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),

            // Pool info
            _PoolInfoSection(pool: pool),

            // Admin panel (pool authority only)
            if (wallet.isConnected && wallet.publicKey == pool.authority) ...[
              const SizedBox(height: 20),
              _AdminSection(
                pool: pool,
                staking: _staking,
                onDepositRewards: (amount) => _handleAdminAction('depositRewards', amount),
                onUpdateSettings: ({BigInt? minStake, BigInt? lockDuration, BigInt? cooldown}) =>
                    _handleUpdateSettings(minStake: minStake, lockDuration: lockDuration, cooldown: cooldown),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Fetch wallet's token balance for the pool's mint
  Future<BigInt> _fetchWalletBalance(String owner) async {
    try {
      // Check both SPL Token and Token2022
      final splAccounts = await _rpc.getTokenAccountsByOwner(owner);
      final t22Accounts = await _rpc.getTokenAccountsByOwner(owner, token2022: true);
      final allAccounts = [...splAccounts, ...t22Accounts];
      var total = BigInt.zero;
      for (final account in allAccounts) {
        if (account.mint == pool.mint) {
          total += account.amount;
        }
      }
      return total;
    } catch (e) {
      return BigInt.zero;
    }
  }

  /// Determine the token program for this pool's mint
  Future<String> _getTokenProgram() async {
    final info = await _rpc.getAccountInfoFull(pool.mint);
    if (info?.owner == token2022ProgramId) return token2022ProgramId;
    return splTokenProgramId;
  }

  Future<void> _handleAdminAction(String action, BigInt amount) async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;
    if (!await InAppUnlockScreen.ensureUnlocked(context)) return;
    if (!mounted) return;

    setState(() => _staking = true);
    try {
      final blockhash = await _rpc.getLatestBlockhash();
      final instructions = <SolanaInstruction>[];

      switch (action) {
        case 'depositRewards':
          instructions.add(createDepositRewardsIx(
            pool: pool.address,
            depositor: wallet.publicKey!,
            amount: amount,
          ));
        default:
          return;
      }

      final tx = buildTransaction(
        recentBlockhash: blockhash,
        feePayer: wallet.publicKey!,
        instructions: instructions,
      );
      final sig = await wallet.signAndSendTransaction(Uint8List.fromList(tx));
      if (!mounted) return;
      if (sig != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$action confirmed: ${sig.substring(0, 8)}...')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _staking = false);
      _loadUserStake();
      wallet.refreshBalances();
    }
  }

  Future<void> _handleUpdateSettings({BigInt? minStake, BigInt? lockDuration, BigInt? cooldown}) async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;
    if (!await InAppUnlockScreen.ensureUnlocked(context)) return;
    if (!mounted) return;

    setState(() => _staking = true);
    try {
      final blockhash = await _rpc.getLatestBlockhash();
      final ix = createUpdatePoolSettingsIx(
        pool: pool.address,
        authority: wallet.publicKey!,
        minStakeAmount: minStake,
        lockDurationSeconds: lockDuration,
        unstakeCooldownSeconds: cooldown,
      );
      final tx = buildTransaction(
        recentBlockhash: blockhash,
        feePayer: wallet.publicKey!,
        instructions: [ix],
      );
      final sig = await wallet.signAndSendTransaction(Uint8List.fromList(tx));
      if (!mounted) return;
      if (sig != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Settings updated: ${sig.substring(0, 8)}...')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _staking = false);
      _loadUserStake();
      wallet.refreshBalances();
    }
  }

  Future<void> _handleAction(String action, {BigInt? unstakeAmount}) async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;
    if (!await InAppUnlockScreen.ensureUnlocked(context)) return;
    if (!mounted) return;

    setState(() => _staking = true);

    try {
      final blockhash = await _rpc.getLatestBlockhash();
      final tokenProgramId = await _getTokenProgram();
      final user = wallet.publicKey!;

      final instructions = <SolanaInstruction>[];

      switch (action) {
        case 'stake':
          final amountText = _stakeController.text.trim();
          if (amountText.isEmpty) return;
          final amountDouble = double.tryParse(amountText);
          if (amountDouble == null || amountDouble <= 0) return;
          final amount = BigInt.from(amountDouble * BigInt.from(10).pow(pool.tokenDecimals).toDouble());
          if (amount < pool.minStakeAmount) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(
                  'Below pool minimum: ${formatTokenAmount(pool.minStakeAmount, pool.tokenDecimals)} ${pool.tokenSymbol ?? ''}',
                )),
              );
            }
            return;
          }
          final beneficiary = _beneficiaryController.text.trim();
          if (beneficiary.length >= 32) {
            instructions.add(createStakeOnBehalfIx(
              pool: pool.address,
              mint: pool.mint,
              staker: user,
              beneficiary: beneficiary,
              amount: amount,
              tokenProgramId: tokenProgramId,
            ));
          } else {
            instructions.add(createStakeIx(
              pool: pool.address,
              mint: pool.mint,
              user: user,
              amount: amount,
              tokenProgramId: tokenProgramId,
            ));
          }
        case 'claim':
          instructions.add(createClaimRewardsIx(pool: pool.address, user: user));
        case 'requestUnstake':
          if (_userStake == null || unstakeAmount == null) return;
          instructions.add(createRequestUnstakeIx(
            pool: pool.address,
            user: user,
            amount: unstakeAmount,
          ));
        case 'unstake':
          if (_userStake == null || unstakeAmount == null) return;
          instructions.add(createUnstakeIx(
            pool: pool.address,
            mint: pool.mint,
            user: user,
            amount: unstakeAmount,
            tokenProgramId: tokenProgramId,
          ));
        case 'completeUnstake':
          instructions.add(createCompleteUnstakeIx(
            pool: pool.address,
            mint: pool.mint,
            user: user,
            tokenProgramId: tokenProgramId,
          ));
        case 'cancelUnstake':
          instructions.add(createCancelUnstakeRequestIx(pool: pool.address, user: user));
        case 'closeAccount':
          instructions.add(createCloseStakeAccountIx(pool: pool.address, user: user));
        default:
          return;
      }

      final tx = buildTransaction(
        recentBlockhash: blockhash,
        feePayer: user,
        instructions: instructions,
      );

      final sig = await wallet.signAndSendTransaction(Uint8List.fromList(tx));

      if (!mounted) return;
      if (sig != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$action confirmed: ${sig.substring(0, 8)}...')),
        );
        _stakeController.clear();
        _beneficiaryController.clear();
        _unstakeController.clear();
      } else if (wallet.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(wallet.error!)),
        );
        wallet.clearError();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      setState(() => _staking = false);
      _loadUserStake();
      wallet.refreshBalances();
    }
  }
}

class _PoolStatsSection extends StatelessWidget {
  final StakingPool pool;

  const _PoolStatsSection({required this.pool});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('POOL STATS', style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StatCard(
                label: 'Total Staked',
                value: formatTokenAmount(pool.totalStaked, pool.tokenDecimals),
                icon: Icons.lock,
                tooltip:
                    'All tokens currently staked across every member of this pool.',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: StatCard(
                label: 'Rewards',
                value: '${formatSol(pool.rewardBalance, decimals: 3)} SOL',
                valueColor: TibaneColors.gold,
                icon: Icons.diamond,
                tooltip:
                    'SOL balance the pool will distribute to stakers as rewards. '
                    'Grows as the pool authority tops it up.',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: StatCard(
                label: 'Tau',
                value: pool.tauFormatted,
                subtitle: 'Decay period',
                icon: Icons.timer,
                tooltip:
                    'Time-weighted decay constant. Your stake weight grows '
                    'toward your full deposit over time at a rate set by '
                    'tau — smaller tau ramps up faster.',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: StatCard(
                label: 'Members',
                value: '${pool.memberCount}',
                icon: Icons.people,
                tooltip:
                    'Number of unique wallets currently staked in this pool.',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

String _formatDuration(int seconds) {
  if (seconds <= 0) return 'Ready';
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final mins = (seconds % 3600) ~/ 60;
  if (days > 0) return hours > 0 ? '${days}d ${hours}h' : '${days}d';
  if (hours > 0) return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
  if (mins > 0) return '${mins}m';
  return '${seconds}s';
}

class _UserStakeSection extends StatelessWidget {
  final StakingPool pool;
  final UserStake? userStake;
  final bool loading;
  final BigInt pendingRewards;
  final double weightPercent;

  const _UserStakeSection({
    required this.pool,
    required this.userStake,
    required this.loading,
    required this.pendingRewards,
    required this.weightPercent,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const TibaneCard(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(color: TibaneColors.orange),
          ),
        ),
      );
    }

    if (userStake == null || userStake!.amount == BigInt.zero) {
      return TibaneCard(
        child: Column(
          children: [
            const Icon(Icons.account_balance, size: 32, color: TibaneColors.textDim),
            const SizedBox(height: 8),
            Text(
              'You have no stake in this pool',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: TibaneColors.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('YOUR STAKE', style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
        const SizedBox(height: 12),
        TibaneCard(
          child: Column(
            children: [
              // Staked amount
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Staked', style: TextStyle(color: TibaneColors.textMuted)),
                  Text(
                    '${formatTokenAmount(userStake!.amount, pool.tokenDecimals)} ${pool.tokenSymbol ?? ''}',
                    style: const TextStyle(
                      color: TibaneColors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Weight
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Weight', style: TextStyle(color: TibaneColors.textMuted)),
                  Text(
                    '${weightPercent.toStringAsFixed(1)}%',
                    style: TextStyle(
                      color: weightPercent > 90
                          ? TibaneColors.cyan
                          : weightPercent > 50
                              ? TibaneColors.gold
                              : TibaneColors.orange,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Weight progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: weightPercent / 100,
                  backgroundColor: TibaneColors.darker,
                  color: weightPercent > 90
                      ? TibaneColors.cyan
                      : weightPercent > 50
                          ? TibaneColors.gold
                          : TibaneColors.orange,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 12),
              // Pending rewards
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Pending Rewards', style: TextStyle(color: TibaneColors.textMuted)),
                  Text(
                    '${formatSol(pendingRewards)} SOL',
                    style: const TextStyle(
                      color: TibaneColors.gold,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              // Unstake request with cooldown status
              if (userStake!.hasUnstakeRequest) ...[
                const SizedBox(height: 12),
                Builder(builder: (context) {
                  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
                  final elapsed = now - userStake!.unstakeRequestTime.toInt();
                  final required = pool.unstakeCooldownSeconds.toInt();
                  final cooldownDone = required == 0 || elapsed >= required;
                  final progress = required > 0
                      ? (elapsed / required).clamp(0.0, 1.0)
                      : 1.0;

                  final badgeColor = cooldownDone ? const Color(0xFF4CAF50) : TibaneColors.orange;
                  final bgColor = cooldownDone
                      ? const Color(0xFF4CAF50).withValues(alpha: 0.08)
                      : TibaneColors.orange.withValues(alpha: 0.08);
                  final borderColor = cooldownDone
                      ? const Color(0xFF4CAF50).withValues(alpha: 0.2)
                      : TibaneColors.orange.withValues(alpha: 0.2);

                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: bgColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: borderColor),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              cooldownDone ? Icons.check_circle : Icons.schedule,
                              size: 16,
                              color: badgeColor,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Unstake request: ${formatTokenAmount(userStake!.unstakeRequestAmount, pool.tokenDecimals)}',
                                style: TextStyle(color: badgeColor, fontSize: 13),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: badgeColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                cooldownDone ? 'Ready' : _formatDuration(required - elapsed),
                                style: TextStyle(color: badgeColor, fontSize: 11, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        if (!cooldownDone && required > 0) ...[
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: progress,
                              backgroundColor: TibaneColors.darker,
                              color: TibaneColors.gold,
                              minHeight: 4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionsSection extends StatelessWidget {
  final StakingPool pool;
  final UserStake userStake;
  final BigInt pendingRewards;
  final TextEditingController unstakeController;
  final void Function(String, {BigInt? amount}) onAction;

  const _ActionsSection({
    required this.pool,
    required this.userStake,
    required this.pendingRewards,
    required this.unstakeController,
    required this.onAction,
  });

  void _setUnstakePercent(int pct) {
    final raw = userStake.amount * BigInt.from(pct) ~/ BigInt.from(100);
    final divisor = BigInt.from(10).pow(pool.tokenDecimals);
    final whole = raw ~/ divisor;
    final frac = raw % divisor;
    final fracStr = frac.toString().padLeft(pool.tokenDecimals, '0');
    // Trim trailing zeros
    var trimmed = fracStr.replaceAll(RegExp(r'0+$'), '');
    unstakeController.text = trimmed.isEmpty ? '$whole' : '$whole.$trimmed';
  }

  BigInt? _parseUnstakeAmount() {
    final text = unstakeController.text.trim();
    if (text.isEmpty) return null;
    final v = double.tryParse(text);
    if (v == null || v <= 0) return null;
    return BigInt.from(v * BigInt.from(10).pow(pool.tokenDecimals).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final hasCooldown = pool.unstakeCooldownSeconds > BigInt.zero;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ACTIONS', style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
        const SizedBox(height: 12),
        // Claim rewards
        if (pendingRewards > BigInt.zero) ...[
          GradientButton(
            label: 'Claim ${formatSol(pendingRewards)} SOL',
            icon: Icons.diamond,
            onPressed: () => onAction('claim'),
            expanded: true,
          ),
          const SizedBox(height: 12),
        ],
        // Unstake section
        if (userStake.hasUnstakeRequest) ...[
          // Pending unstake request
          Builder(builder: (context) {
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final elapsed = now - userStake.unstakeRequestTime.toInt();
            final required = pool.unstakeCooldownSeconds.toInt();
            final cooldownDone = required == 0 || elapsed >= required;

            return TibaneCard(
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SecondaryButton(
                          label: cooldownDone ? 'Complete Unstake' : 'Cooling down...',
                          icon: cooldownDone ? Icons.lock_open : Icons.hourglass_top,
                          onPressed: cooldownDone ? () => onAction('completeUnstake') : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SecondaryButton(
                          label: 'Cancel',
                          icon: Icons.cancel_outlined,
                          onPressed: () => onAction('cancelUnstake'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
        ] else ...[
          // Unstake input with % quick buttons
          Builder(builder: (context) {
            // Check lock state
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final lockDuration = pool.lockDurationSeconds.toInt();
            final unlockTime = userStake.lastStakeTime.toInt() + lockDuration;
            final isLocked = lockDuration > 0 && now < unlockTime;
            final lockRemaining = isLocked ? unlockTime - now : 0;

            return TibaneCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Unstake', style: TextStyle(color: TibaneColors.text, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(
                    'Staked: ${formatTokenAmount(userStake.amount, pool.tokenDecimals)} ${pool.tokenSymbol ?? ''}',
                    style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                  ),
                  // Lock notice
                  if (isLocked) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.lock, size: 14, color: Colors.red),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Locked for ${_formatDuration(lockRemaining)}',
                              style: const TextStyle(color: Colors.red, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  // % quick buttons
                  Row(
                    children: [
                      for (final pct in [25, 50, 75]) ...[
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: GestureDetector(
                              onTap: isLocked ? null : () => _setUnstakePercent(pct),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                decoration: BoxDecoration(
                                  color: TibaneColors.darker,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: TibaneColors.border),
                                ),
                                alignment: Alignment.center,
                                child: Text('$pct%', style: monoStyle(fontSize: 11, color: isLocked ? TibaneColors.textDim : TibaneColors.orange)),
                              ),
                            ),
                          ),
                        ),
                      ],
                      Expanded(
                        child: GestureDetector(
                          onTap: isLocked ? null : () => _setUnstakePercent(100),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            decoration: BoxDecoration(
                              color: isLocked ? TibaneColors.darker : TibaneColors.orange.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: isLocked ? TibaneColors.border : TibaneColors.orange.withValues(alpha: 0.3)),
                            ),
                            alignment: Alignment.center,
                            child: Text('MAX', style: monoStyle(fontSize: 11, color: isLocked ? TibaneColors.textDim : TibaneColors.orange)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: unstakeController,
                    enabled: !isLocked,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      hintText: isLocked ? 'Tokens are locked' : 'Amount to unstake',
                      suffixText: pool.tokenSymbol,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListenableBuilder(
                    listenable: unstakeController,
                    builder: (context, _) {
                      final amount = _parseUnstakeAmount();
                      return SecondaryButton(
                        label: isLocked
                            ? 'Locked (${_formatDuration(lockRemaining)})'
                            : hasCooldown ? 'Request Unstake' : 'Unstake',
                        icon: isLocked ? Icons.lock : Icons.lock_open,
                        expanded: true,
                        onPressed: !isLocked && amount != null
                            ? () => onAction(hasCooldown ? 'requestUnstake' : 'unstake', amount: amount)
                            : null,
                      );
                    },
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }
}

class _WeightMilestonesSection extends StatelessWidget {
  final StakingPool pool;
  final double weightPercent;

  const _WeightMilestonesSection({required this.pool, required this.weightPercent});

  @override
  Widget build(BuildContext context) {
    final tauDays = pool.tauSeconds.toInt() / 86400;
    if (tauDays <= 0) return const SizedBox.shrink();

    // Standard exponential milestones: 1τ=63.2%, 2τ=86.5%, 3τ=95%, 5τ=99.3%
    final milestones = [
      (days: tauDays, pct: 63.2, label: _formatDays(tauDays)),
      (days: tauDays * 2, pct: 86.5, label: _formatDays(tauDays * 2)),
      (days: tauDays * 3, pct: 95.0, label: _formatDays(tauDays * 3)),
      (days: tauDays * 5, pct: 99.3, label: _formatDays(tauDays * 5)),
    ];

    // Calculate days remaining to 90%, 95%, 99%
    final tau = pool.tauSeconds.toInt().toDouble();
    final upcoming = <({int pct, int daysLeft})>[];
    for (final target in [90, 95, 99]) {
      if (weightPercent < target) {
        // Solve: 1 - e^(-t/τ) = target/100 → t = -τ * ln(1 - target/100)
        final totalSeconds = -tau * _ln(1 - target / 100);
        // Current age from weight: t_current = -τ * ln(1 - weight/100)
        final currentAge = weightPercent > 0 ? -tau * _ln(1 - weightPercent / 100) : 0.0;
        final remaining = totalSeconds - currentAge;
        if (remaining > 0) {
          upcoming.add((pct: target, daysLeft: (remaining / 86400).ceil()));
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('WEIGHT MILESTONES', style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
        const SizedBox(height: 12),
        TibaneCard(
          child: Column(
            children: [
              // Milestone markers
              Row(
                children: [
                  for (var i = 0; i < milestones.length; i++) ...[
                    if (i > 0) const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            '${milestones[i].pct}%',
                            style: monoStyle(
                              fontSize: 11,
                              color: weightPercent >= milestones[i].pct
                                  ? TibaneColors.cyan
                                  : TibaneColors.textDim,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            milestones[i].label,
                            style: monoStyle(fontSize: 9, color: TibaneColors.textDim),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            height: 4,
                            decoration: BoxDecoration(
                              color: weightPercent >= milestones[i].pct
                                  ? TibaneColors.cyan
                                  : TibaneColors.darker,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              // Days remaining
              if (upcoming.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final u in upcoming)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${u.pct}% weight',
                            style: monoStyle(fontSize: 11, color: TibaneColors.textMuted)),
                        Text('${u.daysLeft}d remaining',
                            style: monoStyle(fontSize: 11, color: TibaneColors.gold)),
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

  String _formatDays(double days) {
    if (days >= 365) return '${(days / 365).toStringAsFixed(1)}y';
    if (days >= 1) return '${days.round()}d';
    return '${(days * 24).round()}h';
  }

  double _ln(double x) => x > 0 ? log(x) : -999;
}

class _StakeInputSection extends StatelessWidget {
  final TextEditingController controller;
  final TextEditingController beneficiaryController;
  final StakingPool pool;
  final BigInt walletBalance;
  final bool staking;
  final VoidCallback onStake;

  const _StakeInputSection({
    required this.controller,
    required this.beneficiaryController,
    required this.pool,
    required this.walletBalance,
    required this.staking,
    required this.onStake,
  });

  @override
  Widget build(BuildContext context) {
    final displayBalance = walletBalance.toDouble() /
        BigInt.from(10).pow(pool.tokenDecimals).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STAKE TOKENS', style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
        const SizedBox(height: 12),
        TibaneCard(
          child: Column(
            children: [
              // Wallet balance display
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Available',
                    style: TextStyle(color: TibaneColors.textMuted, fontSize: 13),
                  ),
                  Row(
                    children: [
                      Text(
                        '${formatTokenAmount(walletBalance, pool.tokenDecimals)} ${pool.tokenSymbol ?? ''}',
                        style: monoStyle(fontSize: 13, color: TibaneColors.text),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: walletBalance > BigInt.zero
                            ? () => controller.text = displayBalance.toStringAsFixed(pool.tokenDecimals)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: TibaneColors.orange.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: TibaneColors.orange.withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            'MAX',
                            style: monoStyle(fontSize: 10, color: TibaneColors.orange),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  hintText: 'Amount to stake',
                  suffixText: pool.tokenSymbol,
                ),
              ),
              if (pool.minStakeAmount > BigInt.zero) ...[
                const SizedBox(height: 8),
                Text(
                  'Min stake: ${formatTokenAmount(pool.minStakeAmount, pool.tokenDecimals)}',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                ),
              ],
              const SizedBox(height: 8),
              // Stake on behalf
              TextField(
                controller: beneficiaryController,
                decoration: const InputDecoration(
                  hintText: 'Stake for another wallet (optional)',
                  isDense: true,
                ),
                style: monoStyle(fontSize: 11),
              ),
              const SizedBox(height: 16),
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => GradientButton(
                  label: 'Stake',
                  icon: Icons.lock,
                  loading: staking,
                  expanded: true,
                  onPressed: controller.text.trim().isNotEmpty ? onStake : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AdminSection extends StatefulWidget {
  final StakingPool pool;
  final bool staking;
  final void Function(BigInt amount) onDepositRewards;
  final void Function({BigInt? minStake, BigInt? lockDuration, BigInt? cooldown}) onUpdateSettings;

  const _AdminSection({
    required this.pool,
    required this.staking,
    required this.onDepositRewards,
    required this.onUpdateSettings,
  });

  @override
  State<_AdminSection> createState() => _AdminSectionState();
}

class _AdminSectionState extends State<_AdminSection> {
  final _depositController = TextEditingController();
  final _minStakeController = TextEditingController();
  final _lockDurationController = TextEditingController();
  final _cooldownController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final pool = widget.pool;
    if (pool.minStakeAmount > BigInt.zero) {
      _minStakeController.text = formatTokenAmount(pool.minStakeAmount, pool.tokenDecimals);
    }
    if (pool.lockDurationSeconds > BigInt.zero) {
      _lockDurationController.text = (pool.lockDurationSeconds.toInt() ~/ 3600).toString();
    }
    if (pool.unstakeCooldownSeconds > BigInt.zero) {
      _cooldownController.text = (pool.unstakeCooldownSeconds.toInt() ~/ 3600).toString();
    }
  }

  @override
  void dispose() {
    _depositController.dispose();
    _minStakeController.dispose();
    _lockDurationController.dispose();
    _cooldownController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ADMIN', style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
        const SizedBox(height: 12),
        // Deposit rewards
        TibaneCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Deposit Rewards', style: TextStyle(color: TibaneColors.text, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                'Current rewards: ${formatSol(widget.pool.rewardBalance)} SOL',
                style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _depositController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  hintText: 'SOL amount',
                  suffixText: 'SOL',
                ),
              ),
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: _depositController,
                builder: (context, _) {
                  final v = double.tryParse(_depositController.text.trim());
                  final valid = v != null && v > 0;
                  return SecondaryButton(
                    label: 'Deposit',
                    icon: Icons.add_circle,
                    expanded: true,
                    onPressed: valid && !widget.staking
                        ? () {
                            final lamports = BigInt.from(v * 1e9);
                            widget.onDepositRewards(lamports);
                            _depositController.clear();
                          }
                        : null,
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Update pool settings
        TibaneCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Pool Settings', style: TextStyle(color: TibaneColors.text, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _minStakeController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  hintText: 'Min stake amount',
                  suffixText: widget.pool.tokenSymbol,
                  labelText: 'Min Stake',
                  labelStyle: const TextStyle(color: TibaneColors.textDim, fontSize: 12),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _lockDurationController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  hintText: 'Lock duration (hours)',
                  suffixText: 'hours',
                  labelText: 'Lock Duration',
                  labelStyle: TextStyle(color: TibaneColors.textDim, fontSize: 12),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _cooldownController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  hintText: 'Unstake cooldown (hours)',
                  suffixText: 'hours',
                  labelText: 'Unstake Cooldown',
                  labelStyle: TextStyle(color: TibaneColors.textDim, fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              SecondaryButton(
                label: 'Update Settings',
                icon: Icons.settings,
                expanded: true,
                onPressed: widget.staking
                    ? null
                    : () {
                        BigInt? minStake;
                        BigInt? lockDuration;
                        BigInt? cooldown;

                        final minText = _minStakeController.text.trim();
                        if (minText.isNotEmpty) {
                          final v = double.tryParse(minText);
                          if (v != null) {
                            minStake = BigInt.from(v * BigInt.from(10).pow(widget.pool.tokenDecimals).toDouble());
                          }
                        }
                        final lockText = _lockDurationController.text.trim();
                        if (lockText.isNotEmpty) {
                          final h = int.tryParse(lockText);
                          if (h != null) lockDuration = BigInt.from(h * 3600);
                        }
                        final cdText = _cooldownController.text.trim();
                        if (cdText.isNotEmpty) {
                          final h = int.tryParse(cdText);
                          if (h != null) cooldown = BigInt.from(h * 3600);
                        }

                        widget.onUpdateSettings(
                          minStake: minStake,
                          lockDuration: lockDuration,
                          cooldown: cooldown,
                        );
                      },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PoolInfoSection extends StatelessWidget {
  final StakingPool pool;

  const _PoolInfoSection({required this.pool});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('POOL INFO',
            style: monoStyle(fontSize: 10, color: TibaneColors.textDim)),
        const SizedBox(height: 12),
        TibaneCard(
          child: Column(
            children: [
              _InfoRow(
                label: 'Pool',
                value: shortenAddress(pool.address),
                copyValue: pool.address,
                tooltip:
                    'On-chain account that holds the staked tokens and '
                    'tracks total weight.',
              ),
              _InfoRow(
                label: 'Mint',
                value: shortenAddress(pool.mint),
                copyValue: pool.mint,
                tooltip:
                    'The SPL token mint this pool stakes. Every deposit and '
                    'withdrawal uses this exact token.',
              ),
              _InfoRow(
                label: 'Authority',
                value: shortenAddress(pool.authority),
                copyValue: pool.authority,
                tooltip:
                    'Wallet allowed to deposit reward SOL and update pool '
                    'settings (min stake, lock duration, cooldown).',
              ),
              _InfoRow(
                label: 'Tau',
                value: _formatDuration(pool.tauSeconds.toInt()),
                tooltip:
                    'Decay constant. Your stake weight grows toward your '
                    'full deposit at a rate set by tau — smaller tau ramps '
                    'up faster.',
              ),
              if (pool.lockDurationSeconds > BigInt.zero)
                _InfoRow(
                  label: 'Lock',
                  value: _formatDuration(pool.lockDurationSeconds.toInt()),
                  tooltip:
                      'Minimum time your stake stays locked before you can '
                      'request to unstake.',
                ),
              if (pool.unstakeCooldownSeconds > BigInt.zero)
                _InfoRow(
                  label: 'Cooldown',
                  value: _formatDuration(pool.unstakeCooldownSeconds.toInt()),
                  tooltip:
                      'Waiting period between requesting and completing an '
                      'unstake — the tokens are reserved during this window.',
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final String? copyValue;
  final String? tooltip;

  const _InfoRow({
    required this.label,
    required this.value,
    this.copyValue,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final valueWidget = Text(value, style: monoStyle(fontSize: 12));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: TibaneColors.textMuted,
                  fontSize: 13,
                ),
              ),
              if (tooltip != null) ...[
                const SizedBox(width: 6),
                InfoIcon(message: tooltip!),
              ],
            ],
          ),
          if (copyValue != null)
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () {
                Clipboard.setData(ClipboardData(text: copyValue!));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('$label address copied'),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    valueWidget,
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.copy,
                      size: 12,
                      color: TibaneColors.textDim,
                    ),
                  ],
                ),
              ),
            )
          else
            valueWidget,
        ],
      ),
    );
  }
}
