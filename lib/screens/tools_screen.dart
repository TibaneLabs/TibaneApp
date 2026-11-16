import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../l10n/l10n.dart';
import '../models/token_account.dart';
import '../services/rpc_service.dart';
import '../services/solana_common.dart';
import '../services/uk_compliance_service.dart';
import '../services/wallet/reclaim_sol.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../utils/amount.dart';
import '../widgets/tibane_card.dart';
import 'bulk_sell_screen.dart';
import 'incinerator_screen.dart';
import 'staking/staking_pools_screen.dart';
import 'wallet/solana_context.dart';
import 'wallet/widgets/authorize_and_sign.dart';

/// Settings entry point for bulk selling, account cleanup and staking.
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isUk = context.watch<UkComplianceService>().isUk;
    final tools = <Widget>[
      if (!isUk)
        _ToolCard(
          key: const Key('tools-bulk-sell'),
          title: l10n.bulkSellTitle,
          description: l10n.bulkSellDescription,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const BulkSellScreen())),
        ),
      _ToolCard(
        key: const Key('tools-incinerator'),
        title: l10n.incineratorTitle,
        description: l10n.homeIncineratorDescription,
        onTap: () async {
          if (!await ensureSolanaWalletContext(context)) return;
          if (!context.mounted) return;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                backgroundColor: TibaneColors.black,
                appBar: AppBar(title: Text(l10n.incineratorTitle)),
                body: const IncineratorScreen(),
              ),
            ),
          );
        },
      ),
      if (!isUk)
        _ToolCard(
          key: const Key('tools-stake'),
          title: l10n.homeStakeCardTitle,
          description: l10n.homeStakeCardDesc,
          onTap: () async {
            if (!await ensureSolanaWalletContext(context)) return;
            if (!context.mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: TibaneColors.black,
                  appBar: AppBar(title: Text(l10n.homeStakingPoolsTitle)),
                  body: const SafeArea(child: StakingPoolsScreen()),
                ),
              ),
            );
          },
        ),
    ];

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.homeToolsCardTitle)),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: tools.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, i) => tools[i],
        ),
      ),
    );
  }
}

class ReclaimSolCard extends StatefulWidget {
  const ReclaimSolCard({super.key});

  @override
  State<ReclaimSolCard> createState() => _ReclaimSolCardState();
}

typedef _ReclaimScope = ({
  String owner,
  WalletKind kind,
  String? signingContext,
});

class _ReclaimSolCardState extends State<ReclaimSolCard> {
  RpcService? _rpc;
  _ReclaimScope? _scope;
  Future<List<TokenAccount>?>? _estimate;
  final _unresolved = <String, Set<String>>{};
  bool _busy = false;
  int _revision = 0;

  _ReclaimScope? _scopeFor(WalletService wallet) {
    final owner = reclaimSolOwner(wallet);
    if (owner == null) return null;
    return (
      owner: owner,
      kind: wallet.kind,
      signingContext: wallet.kind == WalletKind.inapp
          ? wallet.libwallet.signingContext
          : null,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = _scopeFor(context.watch<WalletService>());
    if (scope != _scope) {
      _revision++;
      _load(scope);
    }
  }

  @override
  void dispose() {
    _rpc?.dispose();
    super.dispose();
  }

  void _load(_ReclaimScope? scope) {
    _scope = scope;
    _estimate = scope == null ? null : _estimateFor(scope.owner);
  }

  Future<List<TokenAccount>?> _estimateFor(String owner) async {
    try {
      final accounts = await scanReclaimableTokenAccounts(
        _rpc ??= RpcService(),
        owner,
      );
      final blocked = _unresolved[owner];
      return accounts
          .where((a) => blocked?.contains(a.pubkey) != true)
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> _claim(List<TokenAccount>? displayed) async {
    if (_busy) return;
    final wallet = context.read<WalletService>();
    final l10n = context.l10n;
    setState(() => _busy = true);
    String? message;
    try {
      // An account switch only previews the new account. It never spends from it.
      if (_scope == null) {
        if (await ensureSolanaWalletContext(context) && mounted) {
          final scope = _scopeFor(wallet);
          if (scope == null) message = l10n.reclaimSolAccountRequired;
        }
        return;
      }
      final scope = _scope!;
      final owner = scope.owner;
      final revision = _revision;
      bool isCurrent() =>
          mounted && _revision == revision && _scopeFor(wallet) == scope;
      if (!isCurrent()) return;
      if (displayed == null) {
        message = l10n.reclaimSolLoadError;
        return;
      }
      if (displayed.isEmpty) {
        message = l10n.reclaimSolEmpty;
        return;
      }

      final total = formatExactTokenAmount(reclaimableLamports(displayed), 9);
      final auth = await authorizeBatch(
        context,
        transactionReviewed: true,
        confirmationTitle: displayed.any(isReclaimDust)
            ? l10n.reclaimSolDustClaimPrompt(total)
            : l10n.reclaimSolClaimPrompt(total),
      );
      if (auth == null || !isCurrent()) return;
      final rpc = _rpc!;
      final current = {
        for (final a in await scanReclaimableTokenAccounts(rpc, owner))
          a.pubkey: a,
      };
      if (!isCurrent()) return;
      for (final a in displayed) {
        final fresh = current[a.pubkey];
        if (fresh == null ||
            fresh.mint != a.mint ||
            fresh.amount != a.amount ||
            fresh.decimals != a.decimals ||
            fresh.isToken2022 != a.isToken2022 ||
            fresh.rentLamports != a.rentLamports) {
          message = l10n.reclaimSolAccountsChanged;
          return;
        }
      }

      final submitted = <String, List<String>>{};
      final blocked = _unresolved.putIfAbsent(owner, () => <String>{});
      var uncertain = false;
      try {
        for (
          var offset = 0;
          offset < displayed.length && isCurrent();
          offset += 10
        ) {
          final batch = displayed
              .skip(offset)
              .take(10)
              .map((a) => current[a.pubkey]!)
              .toList();
          final blockhash = await rpc.getLatestBlockhash().timeout(
            const Duration(seconds: 10),
          );
          if (!isCurrent()) break;
          final tx = Uint8List.fromList(
            buildTransaction(
              recentBlockhash: blockhash,
              feePayer: owner,
              instructions: buildReclaimSolInstructions(batch, owner),
            ),
          );
          final sim = await rpc
              .simulateTransaction(tx)
              .timeout(const Duration(seconds: 10));
          if (!isCurrent()) break;
          if (!sim.containsKey('err') || sim['err'] != null) {
            message = l10n.reclaimSolPreflightFailed;
            break;
          }
          final ids = batch.map((a) => a.pubkey).toList();
          blocked.addAll(ids);
          uncertain = true;
          final signature = await signAndSendOne(wallet, tx, auth.keys);
          if (signature == null || signature.isEmpty) break;
          submitted[signature] = ids;
          uncertain = false;
        }
      } catch (_) {
        if (!uncertain) message = l10n.reclaimSolExecutionError;
      }
      if (mounted && (submitted.isNotEmpty || uncertain)) {
        final (confirmed, failed) = await _settlementCounts(
          rpc,
          submitted,
          blocked,
        );
        final sent = submitted.values.fold(0, (sum, ids) => sum + ids.length);
        if (failed > 0) message ??= l10n.reclaimSolExecutionError;
        if (uncertain || confirmed + failed < sent) {
          message = [?message, l10n.reclaimSolCheckActivity].join('\n');
        }
        if (isCurrent()) wallet.notifyTxCommitted();
      }
    } catch (_) {
      message = l10n.reclaimSolExecutionError;
    } finally {
      if (mounted) {
        if (message != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
        setState(() {
          _busy = false;
          _load(_scopeFor(wallet));
        });
      }
    }
  }

  Future<(int, int)> _settlementCounts(
    RpcService rpc,
    Map<String, List<String>> pending,
    Set<String> blocked,
  ) async {
    final remaining = Map.of(pending);
    var confirmed = 0;
    var failed = 0;
    for (
      var attempt = 0;
      attempt < 6 && remaining.isNotEmpty && mounted;
      attempt++
    ) {
      final signatures = remaining.keys.take(256).toList();
      try {
        final statuses = await rpc
            .getSignatureStatuses(signatures)
            .timeout(const Duration(seconds: 4));
        for (var i = 0; i < signatures.length; i++) {
          if (statuses[i] == SolanaSignatureStatus.pending) continue;
          final accounts = remaining.remove(signatures[i])!;
          if (statuses[i] == SolanaSignatureStatus.confirmed) {
            confirmed += accounts.length;
          } else {
            failed += accounts.length;
            blocked.removeAll(accounts);
          }
        }
      } catch (_) {
        // Unavailable status is not proof that the transaction failed.
      }
      if (remaining.isNotEmpty && mounted && attempt < 5) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    return (confirmed, failed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FutureBuilder<List<TokenAccount>?>(
      future: _estimate,
      builder: (context, snapshot) {
        final accounts = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        return _ToolCard(
          title: l10n.reclaimSolTitle,
          description: l10n.toolsReclaimSolDescription,
          onTap: _busy || snapshot.connectionState == ConnectionState.waiting
              ? null
              : () => _claim(accounts),
          badge: accounts == null
              ? null
              : '${formatSol(reclaimableLamports(accounts), decimals: 3)} SOL',
          busy: _busy,
        );
      },
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    super.key,
    required this.title,
    required this.description,
    required this.onTap,
    this.badge,
    this.busy = false,
  });

  final String title;
  final String description;
  final VoidCallback? onTap;
  final String? badge;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    const badgeInset = 13.0;
    const cardInset = 20.0;
    final textTheme = Theme.of(context).textTheme;
    final heading = Text(
      title,
      style: textTheme.titleMedium?.apply(
        fontSizeFactor: 1.15,
        color: TibaneColors.text,
      ),
    );
    return TibaneCard(
      onTap: onTap,
      padding: badge == null && !busy
          ? null
          : const EdgeInsets.fromLTRB(
              cardInset,
              cardInset,
              badgeInset,
              cardInset,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (badge == null && !busy)
            heading
          else
            Row(
              children: [
                Expanded(child: heading),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: busy
                        ? const SizedBox.square(
                            dimension: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: TibaneColors.orange,
                            ),
                          )
                        : DecoratedBox(
                            decoration: BoxDecoration(
                              color: TibaneColors.orange.withValues(
                                alpha: 0.12,
                              ),
                              border: Border.all(color: TibaneColors.orange),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12 * 1.15,
                                vertical: 4.8 * 1.15,
                              ),
                              child: Text(
                                badge!,
                                textAlign: TextAlign.center,
                                style: textTheme.labelMedium
                                    ?.copyWith(
                                      color: TibaneColors.orange,
                                      fontWeight: FontWeight.w600,
                                    )
                                    .apply(fontSizeFactor: 1.2 * 1.15),
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Padding(
            padding: badge == null && !busy
                ? EdgeInsets.zero
                : const EdgeInsets.only(right: cardInset - badgeInset),
            child: Text(description, style: cardSubtitleStyle(context)),
          ),
        ],
      ),
    );
  }
}
