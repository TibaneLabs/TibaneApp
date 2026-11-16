import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show NetworkType;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../models/staking_pool.dart';
import '../../services/chiefstaker_api.dart';
import '../../services/rpc_service.dart';
import '../../services/solana_common.dart';
import '../../services/staking_positions.dart';
import '../../services/uk_compliance_service.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/amount.dart';
import '../../utils/context_extensions.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/token_icon.dart';
import '../../widgets/wallet_error_display.dart';
import '../wallet/widgets/authorize_and_sign.dart';
import 'staking_detail_screen.dart';

typedef _Source = ({String owner, WalletKind kind, String? signingContext});

class MyStakedScreen extends StatefulWidget {
  final List<StakingPool> directory;

  const MyStakedScreen({super.key, required this.directory});

  @override
  State<MyStakedScreen> createState() => _MyStakedScreenState();
}

class _MyStakedScreenState extends State<MyStakedScreen> {
  final _rpc = RpcService();
  late final _positions = StakingPositions(_rpc, ChiefStakerApi());
  _Source? _source;
  Future<List<StakingPosition>>? _load;
  bool _claiming = false;
  final _pending = <_Source, String>{};

  _Source? _current(WalletService wallet) {
    final owner = wallet.publicKey;
    if (!wallet.isConnected || owner == null || owner.isEmpty) return null;
    if (owner.length < 32 || owner.length > 44) return null;
    try {
      if (base58Decode(owner).length != 32) return null;
    } on FormatException {
      return null;
    }
    final inApp = wallet.kind == WalletKind.inapp;
    final network = inApp ? wallet.libwallet.currentNetwork : null;
    if (network != null &&
        (network.type != NetworkType.solana || network.testNet)) {
      return null;
    }
    return (
      owner: owner,
      kind: wallet.kind,
      signingContext: inApp ? wallet.libwallet.signingContext : null,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wallet = context.watch<WalletService>();
    final source = context.watch<UkComplianceService>().isUk
        ? null
        : _current(wallet);
    if (source == _source) return;
    _source = source;
    _load = source == null ? null : _fetch(source);
  }

  @override
  void dispose() {
    _rpc.dispose();
    super.dispose();
  }

  Future<List<StakingPosition>> _fetch(_Source source) => _positions
      .load(source.owner, widget.directory)
      .timeout(const Duration(seconds: 20));

  Future<SolanaSignatureStatus> _status(String signature) async {
    try {
      return (await _rpc
              .getSignatureStatuses([signature])
              .timeout(const Duration(seconds: 4)))
          .single;
    } catch (_) {
      return SolanaSignatureStatus.pending;
    }
  }

  Future<void> _refresh() async {
    final source = _source;
    if (source == null || !mounted) return;
    final signature = _pending[source];
    if (signature != null) {
      final status = await _status(signature);
      if (!mounted || source != _source) return;
      if (status != SolanaSignatureStatus.pending) {
        _pending.remove(source);
        if (status == SolanaSignatureStatus.failed) {
          _notify(context.l10n.stakingClaimFailed);
        }
      }
    }
    final load = _fetch(source);
    setState(() {
      _load = load;
    });
    try {
      await load;
    } catch (_) {
      // FutureBuilder renders the error state.
    }
  }

  bool _stillActive(_Source source, WalletService wallet) =>
      mounted &&
      source == _current(wallet) &&
      !context.read<UkComplianceService>().isUk;

  void _notify(String message) =>
      context.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _claim(List<StakingPosition> positions) async {
    final source = _source;
    if (_claiming || source == null || _pending.containsKey(source)) return;
    if (positions.isEmpty || positions.length > maxClaimsPerTransaction) return;
    final wallet = context.read<WalletService>();
    if (!_stillActive(source, wallet)) return;
    final l10n = context.l10n;
    setState(() => _claiming = true);
    try {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.stakingClaimReview),
          content: Text(l10n.stakingClaimEstimate(_sol(_sum(positions)))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.actionConfirm),
            ),
          ],
        ),
      );
      if (approved != true || !_stillActive(source, wallet)) return;
      final blockhash = await _rpc.getLatestBlockhash().timeout(
        const Duration(seconds: 10),
      );
      if (!_stillActive(source, wallet)) return;
      final transaction = buildStakingClaim(
        owner: source.owner,
        blockhash: blockhash,
        pools: positions.map((position) => position.pool.address),
      );
      final simulation = await _rpc
          .simulateTransaction(transaction)
          .timeout(const Duration(seconds: 10));
      if (!mounted || !_stillActive(source, wallet)) return;
      if (!simulation.containsKey('err') || simulation['err'] != null) {
        _notify(l10n.stakingClaimFailed);
        return;
      }
      final signatures = await authorizeAndSignAndSend(context, [transaction]);
      if (signatures == null) return;
      final signature = signatures.firstOrNull;
      if (signature == null || signature.isEmpty) {
        if (_stillActive(source, wallet)) _notify(l10n.stakingClaimUnconfirmed);
        return;
      }
      if (!mounted) return;
      _pending[source] = signature;
      wallet.notifyTxCommitted();
      if (!_stillActive(source, wallet)) return;

      var status = SolanaSignatureStatus.pending;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (_stillActive(source, wallet) &&
          DateTime.now().isBefore(deadline)) {
        status = await _status(signature);
        if (status != SolanaSignatureStatus.pending) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (!_stillActive(source, wallet)) return;
      switch (status) {
        case SolanaSignatureStatus.confirmed:
          _pending.remove(source);
          _notify(l10n.stakingClaimConfirmed);
          await _refresh();
        case SolanaSignatureStatus.failed:
          _pending.remove(source);
          _notify(l10n.stakingClaimFailed);
          await _refresh();
        case SolanaSignatureStatus.pending:
          _notify(l10n.stakingClaimUnconfirmed);
      }
    } catch (error) {
      if (mounted && _stillActive(source, wallet)) {
        showWalletError(context, error);
      }
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }

  static BigInt _sum(Iterable<StakingPosition> positions) => positions.fold(
    BigInt.zero,
    (total, position) => total + position.rewards,
  );

  static String _sol(BigInt lamports) =>
      '${formatExactTokenAmount(lamports, 9)} SOL';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final blocked = context.watch<UkComplianceService>().isUk;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.stakingMyStaked),
        actions: [
          if (_source != null && !blocked)
            IconButton(
              tooltip: l10n.actionRefresh,
              onPressed: _claiming ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: blocked
          ? Center(
              child: Text(
                l10n.stakingUnavailableTitle,
                textAlign: TextAlign.center,
              ),
            )
          : _source == null
          ? Center(
              child: Text(
                l10n.stakingSolanaAccountRequired,
                textAlign: TextAlign.center,
              ),
            )
          : FutureBuilder<List<StakingPosition>>(
              key: ValueKey(_source),
              future: _load,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.stakingPositionsLoadError,
                          textAlign: TextAlign.center,
                        ),
                        TextButton(
                          onPressed: _refresh,
                          child: Text(l10n.actionRetry),
                        ),
                      ],
                    ),
                  );
                }
                final positions = snapshot.data ?? const <StakingPosition>[];
                final claimable = positions
                    .where((p) => p.rewards > BigInt.zero)
                    .toList();
                final tooMany = claimable.length > maxClaimsPerTransaction;
                final pending = _pending.containsKey(_source);
                final disabled = _claiming || pending;
                return RefreshIndicator(
                  onRefresh: () async {
                    if (!_claiming) await _refresh();
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                    children: [
                      if (_claiming) const LinearProgressIndicator(),
                      if (pending && !_claiming) ...[
                        Text(l10n.stakingClaimUnconfirmed),
                        const SizedBox(height: 12),
                      ],
                      if (positions.isEmpty)
                        Text(
                          l10n.stakingNoPositions,
                          textAlign: TextAlign.center,
                        )
                      else ...[
                        Text(l10n.stakingTotalClaimable),
                        Text(
                          _sol(_sum(claimable)),
                          style: context.textTheme.headlineSmall?.copyWith(
                            color: TibaneColors.success,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton(
                            onPressed: disabled || tooMany || claimable.isEmpty
                                ? null
                                : () => _claim(claimable),
                            child: Text(l10n.stakingClaimAll),
                          ),
                        ),
                        if (tooMany) Text(l10n.stakingClaimIndividualOnly),
                        const SizedBox(height: 16),
                        for (final position in positions)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _positionCard(position, disabled),
                          ),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _positionCard(StakingPosition position, bool disabled) {
    final l10n = context.l10n;
    final pool = position.pool;
    final symbol = pool.tokenSymbol ?? pool.mint.substring(0, 5);
    final amount = formatExactTokenAmount(
      position.stake.amount,
      pool.tokenDecimals,
    );
    return TibaneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TokenIcon(
                mint: pool.mint,
                imageUrl: pool.tokenImage,
                symbol: symbol,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  pool.tokenName ?? symbol,
                  style: context.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(l10n.stakingStakedAmount(amount, symbol)),
          Text('${l10n.stakingPendingRewards}: ${_sol(position.rewards)}'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton(
                onPressed: disabled
                    ? null
                    : () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => StakingDetailScreen(pool: pool),
                          ),
                        );
                        if (mounted) await _refresh();
                      },
                child: Text(l10n.stakingStakeButton),
              ),
              FilledButton(
                onPressed: disabled || position.rewards <= BigInt.zero
                    ? null
                    : () => _claim([position]),
                child: Text(l10n.stakingClaimAction),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
