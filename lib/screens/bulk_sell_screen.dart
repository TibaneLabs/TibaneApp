import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../services/balances_store.dart';
import '../services/jupiter_service.dart';
import '../services/wallet/bulk_sell_service.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../utils/amount.dart';
import '../utils/wallet_error.dart';
import '../widgets/token_icon.dart';
import 'wallet/widgets/authorize_and_sign.dart';

class BulkSellScreen extends StatefulWidget {
  const BulkSellScreen({super.key}) : service = null, authorize = null;

  @visibleForTesting
  const BulkSellScreen.testing({
    super.key,
    required this.service,
    required this.authorize,
  });

  final BulkSellService? service;
  final Future<BatchAuth?> Function(BuildContext)? authorize;

  @override
  State<BulkSellScreen> createState() => _BulkSellScreenState();
}

class _BulkSellScreenState extends State<BulkSellScreen> {
  late final WalletService _wallet;
  late final BulkSellService _service;
  BulkSellAccount? _account;
  List<TokenHolding>? _holdings;
  BulkSellReview? _review;
  final _selected = <String>{};
  final _outcomes = <String, BulkSellOutcome>{};
  bool _invalidated = false;
  bool _busy = false;
  bool _confirming = false;
  bool _results = false;
  bool _loadFailed = false;
  String? _error;
  Timer? _quoteTimer;
  int _quoteRequest = 0;

  bool get _isCurrent =>
      mounted &&
      !_invalidated &&
      _account != null &&
      bulkSellAccountFor(_wallet) == _account;

  @override
  void initState() {
    super.initState();
    _wallet = context.read<WalletService>();
    _service =
        widget.service ??
        BulkSellService(client: _wallet.libwallet.ensureClient);
    _account = bulkSellAccountFor(_wallet);
    _wallet.addListener(_onWalletChange);
    if (_account != null) unawaited(_load());
  }

  @override
  void dispose() {
    _quoteTimer?.cancel();
    _wallet.removeListener(_onWalletChange);
    _service.dispose();
    super.dispose();
  }

  void _onWalletChange() {
    if (_account == null ||
        _invalidated ||
        bulkSellAccountFor(_wallet) == _account) {
      return;
    }
    setState(() => _invalidated = true);
  }

  Future<void> _load() async {
    if (!_isCurrent || _busy) return;
    setState(() {
      _busy = true;
      _loadFailed = false;
    });
    try {
      final holdings = await _service.holdings(_account!);
      if (_isCurrent) setState(() => _holdings = holdings);
    } catch (_) {
      if (_isCurrent) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare() async {
    final holdings = _holdings;
    if (!_isCurrent || _busy || holdings == null || _selected.isEmpty) return;
    final tokens = holdings.where((t) => _selected.contains(t.mint));
    final request = ++_quoteRequest;
    bool isCurrent() => _isCurrent && request == _quoteRequest;
    _quoteTimer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final review = await _service.prepare(
        _account!,
        tokens.toList(),
        isCurrent: isCurrent,
      );
      if (!isCurrent()) return;
      setState(() => _review = review);
      if (review.hasQuotes && !review.expired) {
        final expires = review.lines
            .map((line) => line.quote!.expiresAt)
            .reduce((a, b) => a.isBefore(b) ? a : b);
        _quoteTimer = Timer(
          expires.difference(DateTime.now()) + const Duration(milliseconds: 20),
          () {
            if (mounted && !_results) setState(() {});
          },
        );
      }
    } catch (_) {
      if (isCurrent() && mounted) {
        setState(() => _error = context.l10n.bulkSellQuoteError);
      }
    } finally {
      if (mounted && request == _quoteRequest) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final review = _review;
    if (!_isCurrent ||
        _busy ||
        review == null ||
        !review.hasQuotes ||
        review.expired) {
      return;
    }
    final l10n = context.l10n;
    final balances = context.read<BalancesStore>();
    setState(() {
      _busy = true;
      _confirming = true;
      _error = null;
    });
    try {
      final balance = await _service.feeBalance(review.account);
      if (!_isCurrent) return;
      if (balance < review.feeBudget) {
        setState(() => _error = l10n.bulkSellInsufficientSol);
        return;
      }
      if (!mounted || review.expired) return;
      final auth =
          await (widget.authorize?.call(context) ??
              authorizeBatch(context, transactionReviewed: true));
      final keys = auth?.keys;
      if (!_isCurrent || review.expired || keys == null || keys.isEmpty) return;
      _quoteTimer?.cancel();
      setState(() => _results = true);
      await _service.execute(
        review,
        keys,
        canSubmit: () => _isCurrent,
        isOpen: () => mounted,
        onUpdate: (mint, outcome) {
          if (mounted) setState(() => _outcomes[mint] = outcome);
        },
      );
    } catch (_) {
      if (mounted) setState(() => _error = l10n.bulkSellExecutionError);
    } finally {
      if (_isCurrent &&
          _outcomes.values.any(
            (o) =>
                o.status == BulkSellStatus.sold ||
                o.status == BulkSellStatus.pending ||
                o.signature != null,
          )) {
        // Refresh once for the batch; each signature remains in its own result.
        balances.onTxCommitted(null);
      }
      if (mounted) {
        setState(() {
          _confirming = false;
          _busy = false;
        });
      }
    }
  }

  void _back() {
    if (_confirming) return;
    if (_review != null && !_results) {
      _quoteTimer?.cancel();
      _quoteRequest++;
      setState(() {
        _review = null;
        _error = null;
        _busy = false;
      });
    } else {
      Navigator.of(context).maybePop();
    }
  }

  String _sol(BigInt value) => '${formatExactTokenAmount(value, 9)} SOL';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final review = _review;
    final isReview = review != null && !_results;
    final title = _results
        ? l10n.bulkSellResults
        : isReview
        ? l10n.bulkSellReview
        : l10n.bulkSellTitle;
    return PopScope(
      canPop: !_confirming && !isReview,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && isReview && !_confirming) _back();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_invalidated) _notice(l10n.bulkSellAccountChanged),
              if (_error != null) _notice(_error!),
              if (review != null)
                ..._reviewContent(review, l10n)
              else if (_account == null)
                _notice(l10n.bulkSellAccountRequired)
              else if (!_invalidated && _loadFailed) ...[
                _notice(l10n.bulkSellLoadError),
                TextButton(
                  onPressed: _busy ? null : _load,
                  child: Text(l10n.actionRetry),
                ),
              ] else if (!_invalidated && _holdings != null)
                ..._selectionContent(_holdings!, l10n),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: _results
              ? _button(
                  l10n.actionDone,
                  TibaneColors.orange,
                  _busy ? null : _back,
                )
              : Row(
                  children: [
                    Expanded(
                      child: _button(
                        l10n.actionCancel,
                        TibaneColors.surface,
                        _confirming ? null : _back,
                        labelScale: 1.2,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _button(
                        isReview
                            ? (review.expired
                                  ? l10n.actionRetry
                                  : l10n.actionConfirm)
                            : l10n.bulkSellTitle,
                        TibaneColors.orange,
                        _busy || !_isCurrent
                            ? null
                            : isReview
                            ? (review.expired
                                  ? _prepare
                                  : review.hasQuotes
                                  ? _confirm
                                  : null)
                            : (_selected.isEmpty ? null : _prepare),
                        labelScale: isReview ? 1 : 1.2,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _notice(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Text(text, style: const TextStyle(color: TibaneColors.warning)),
  );

  Widget _button(
    String label,
    Color background,
    VoidCallback? action, {
    double labelScale = 1,
  }) => FilledButton(
    style: FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: background == TibaneColors.surface
          ? TibaneColors.text
          : TibaneColors.black,
      minimumSize: const Size(0, 48),
      textStyle: labelScale == 1
          ? null
          : Theme.of(
              context,
            ).textTheme.labelLarge?.apply(fontSizeFactor: labelScale),
    ),
    onPressed: action,
    child: Text(label, textAlign: TextAlign.center),
  );

  Iterable<Widget> _selectionContent(
    List<TokenHolding> tokens,
    AppLocalizations l10n,
  ) sync* {
    if (tokens.isEmpty) {
      yield _notice(l10n.bulkSellEmpty);
      return;
    }
    final allSelected = _selected.length == tokens.length;
    yield _selectionTile(
      key: const ValueKey('bulk-sell-select-all'),
      title: Text(l10n.bulkSellSelectAll),
      value: _selected.isEmpty || allSelected ? allSelected : null,
      tristate: true,
      onTap: _busy
          ? null
          : () => setState(() {
              _selected.clear();
              if (!allSelected) _selected.addAll(tokens.map((t) => t.mint));
            }),
    );
    for (final token in tokens) {
      final selected = _selected.contains(token.mint);
      yield _selectionTile(
        key: ValueKey(token.mint),
        value: selected,
        onTap: _busy
            ? null
            : () => setState(() {
                if (selected) {
                  _selected.remove(token.mint);
                } else {
                  _selected.add(token.mint);
                }
              }),
        title: _tokenTitle(token),
        subtitle: _tokenDetails(token),
        leading: _icon(token),
      );
    }
  }

  Widget _selectionTile({
    required Key key,
    required Widget title,
    required bool? value,
    required VoidCallback? onTap,
    bool tristate = false,
    Widget? subtitle,
    Widget? leading,
  }) => MergeSemantics(
    key: key,
    child: ListTile(
      enabled: onTap != null,
      onTap: onTap,
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: Transform.scale(
        scale: 1.15,
        child: Checkbox(
          shape: const CircleBorder(),
          value: value,
          tristate: tristate,
          onChanged: onTap == null ? null : (_) => onTap(),
        ),
      ),
    ),
  );

  Widget _tokenTitle(TokenHolding token) => Text(
    token.name.isEmpty ? token.symbol : token.name,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(
      fontSize: 16.1,
      fontWeight: FontWeight.w600,
      color: TibaneColors.text,
    ),
  );

  Widget _tokenDetails(TokenHolding token, {String? status}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (token.symbol.isNotEmpty &&
          token.symbol != token.name &&
          token.name.isNotEmpty)
        Text(
          token.symbol,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: monoStyle(fontSize: 13.2, color: TibaneColors.textMuted),
        ),
      Text(
        formatExactTokenAmount(token.balance, token.decimals),
        style: monoStyle(fontSize: 18.4),
      ),
      if (status != null) Text(status),
    ],
  );

  Widget _icon(TokenHolding token) => TokenIcon(
    mint: token.mint,
    imageUrl: token.imageUrl,
    symbol: token.symbol,
    size: 44.85,
  );

  Iterable<Widget> _reviewContent(
    BulkSellReview review,
    AppLocalizations l10n,
  ) sync* {
    if (!_results) {
      if (review.hasQuotes) {
        yield Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _sol(review.minimum),
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w500)
                    .apply(fontSizeFactor: 1.15),
              ),
              const SizedBox(height: 8),
              Text(
                '${l10n.bulkSellFees}: ${review.estimatedFees == null ? l10n.bulkSellFeeUnknown : _sol(review.estimatedFees!)}',
              ),
            ],
          ),
        );
      } else {
        yield _notice(l10n.bulkSellReviewBlocked);
      }
      if (review.expired) yield _notice(l10n.bulkSellQuoteExpired);
    }
    for (final line in review.lines) {
      final token = line.token;
      final outcome = _outcomes[token.mint];
      final signature = outcome?.signature;
      final status = _results
          ? switch (outcome?.status) {
              BulkSellStatus.sold => l10n.bulkSellSold,
              BulkSellStatus.failed => l10n.bulkSellFailed,
              BulkSellStatus.expired => l10n.bulkSellExpiredNotSent,
              BulkSellStatus.submitting => l10n.bulkSellSubmitting,
              BulkSellStatus.pending => l10n.bulkSellPending,
              _ => l10n.bulkSellNotSent,
            }
          : line.quote != null
          ? '${l10n.swapMinReceive}: ${_sol(line.minimum)}'
          : line.error != null
          ? walletErrorMessageForContext(context, line.error!)
          : l10n.bulkSellQuoteError;
      yield ListTile(
        leading: _icon(token),
        title: _tokenTitle(token),
        subtitle: _tokenDetails(token, status: status),
        trailing: signature == null
            ? null
            : IconButton(
                tooltip: l10n.bulkSellViewOnSolscan,
                icon: const Icon(Icons.open_in_new, color: TibaneColors.orange),
                onPressed: () => launchUrl(
                  Uri.https('solscan.io', '/tx/$signature'),
                  mode: LaunchMode.externalApplication,
                ),
              ),
      );
    }
  }
}
