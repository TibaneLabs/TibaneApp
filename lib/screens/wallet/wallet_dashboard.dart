import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:libwallet/libwallet.dart' show Asset, NetworkType, Transaction;
import 'package:provider/provider.dart';

import '../../constants/solana_constants.dart';
import '../../models/transaction_activity.dart';
import '../../l10n/l10n.dart';
import '../../services/balances_store.dart';
import '../../services/jupiter_service.dart';
import '../../services/portfolio_performance.dart';
import '../../services/wallet/asset_network.dart';
import '../../services/uk_compliance_service.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/network_logos.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/token_icon.dart';
import '../swap_screen.dart';
import '../token_detail_screen.dart';
import 'receive_screen.dart';
import 'send_screen.dart';
import 'transaction_details_screen.dart';
import 'widgets/activity_token_amount.dart';
import 'widgets/wallet_action_button.dart';
import '../../utils/context_extensions.dart';
import '../../widgets/wallet_error_display.dart';

class WalletDashboard extends StatefulWidget {
  const WalletDashboard({super.key});

  @override
  State<WalletDashboard> createState() => _WalletDashboardState();
}

class _WalletDashboardState extends State<WalletDashboard> {
  // Holdings + transactions + their refresh now live in BalancesStore, read via
  // context.watch<BalancesStore>() in build — the dashboard is a pure consumer.
  int _selectedTab = 0; // 0 = Tokens, 1 = Activity

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wallet = context.watch<WalletService>();
    final store = context.watch<BalancesStore>();
    final addr = wallet.publicKey ?? '';
    final displayTokens = _displayTokens(
      wallet,
      store.holdings,
      nativeSolHolding: store.nativeSolHolding,
    );

    return RefreshIndicator(
      // Pull-to-refresh: the store forces fresh balances + on-chain SPL
      // discovery + a tx-history backfill sweep, then reloads holdings + tx.
      onRefresh: store.refresh,
      color: TibaneColors.orange,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Total portfolio balance from the current native position and
          // non-native token holdings.
          Center(
            child: Builder(
              builder: (context) {
                final nativeAssets = wallet.assets
                    .where(
                      (asset) =>
                          asset.isNative &&
                          wallet.libwallet.currentNetwork != null &&
                          assetBelongsToNetwork(
                            asset,
                            wallet.libwallet.currentNetwork!,
                          ),
                    )
                    .toList();
                final libwalletNativeFiat = nativeAssets.fold<double>(
                  0,
                  (sum, a) => sum + (a.fiatAmount?.toDouble() ?? 0),
                );
                final nativeSol = store.nativeSolHolding;
                final nativeHolding = displayTokens.firstOrNull;
                final nativeFiat =
                    nativeHolding?.valueUsd ??
                    (wallet.libwallet.currentNetwork?.type == NetworkType.solana
                        ? nativeSol?.valueUsd
                        : null) ??
                    libwalletNativeFiat;
                final nativeFiatUnknown =
                    nativeHolding != null &&
                    nativeHolding.uiBalance > 0 &&
                    nativeHolding.valueUsd == null;
                // Sum every non-native displayed token's USD value. On
                // Solana these are the Jupiter holdings; on EVM/BTC they
                // are the libwallet asset rows — keeping the headline in
                // step with the token list on every chain.
                final tokensFiat = displayTokens
                    .where((h) => !h.mint.endsWith('.NATIVE'))
                    .fold<double>(0, (sum, h) => sum + (h.valueUsd ?? 0));
                final totalUsd = nativeFiat + tokensFiat;
                final performance = nativeFiatUnknown
                    ? null
                    : calculatePortfolioPerformance24h([
                        if (nativeHolding != null)
                          PortfolioPosition24h(
                            currentValueUsd: nativeFiat,
                            percentChange24h:
                                nativeHolding.priceChange24h ??
                                nativeAssets
                                    .firstOrNull
                                    ?.fiatQuote
                                    ?.percentChange24h,
                          ),
                        for (final token in displayTokens)
                          if (!token.mint.endsWith('.NATIVE'))
                            PortfolioPosition24h(
                              currentValueUsd: token.valueUsd ?? 0,
                              percentChange24h: token.priceChange24h,
                            ),
                      ]);
                // Express the dollar total in SOL when we have enough
                // signal to compute the SOL price (native fiat ÷ native
                // ui-balance). Falls back to silence on non-Solana
                // networks or when balances haven't loaded yet rather
                // than printing a misleading 0.
                final solUi =
                    nativeSol?.uiBalance ?? wallet.solBalance.toDouble() / 1e9;
                final solPriceUsd = (nativeFiat > 0 && solUi > 0)
                    ? nativeFiat / solUi
                    : null;
                final totalInSol = solPriceUsd != null
                    ? totalUsd / solPriceUsd
                    : null;
                final totalStyle = context.textTheme.displaySmall;
                return Column(
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        nativeFiatUnknown
                            ? '--'
                            : '\$${totalUsd.toStringAsFixed(2)}',
                        key: const Key('wallet-total-balance'),
                        style: totalStyle?.copyWith(
                          fontSize: (totalStyle.fontSize ?? 36) * 1.38 * 1.15,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                    if (totalInSol != null) ...[
                      Text(
                        '${totalInSol.toStringAsFixed(4)} SOL',
                        style: monoStyle(
                          fontSize: 13,
                          color: TibaneColors.textMuted,
                        ),
                      ),
                    ],
                    if (performance != null) ...[
                      const SizedBox(height: 8),
                      _PortfolioPerformanceLine(performance: performance),
                    ],
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 24),

          // Action buttons — swap entry hidden in UK mode.
          Builder(
            builder: (context) {
              final isUk = context.watch<UkComplianceService>().isUk;
              return Row(
                children: [
                  WalletActionButton(
                    icon: Icons.arrow_downward,
                    label: l10n.receiveTitle,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ReceiveScreen()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  WalletActionButton(
                    icon: Icons.arrow_upward,
                    label: l10n.dashboardSend,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SendScreen()),
                    ),
                  ),
                  if (!isUk) ...[
                    const SizedBox(width: 12),
                    WalletActionButton(
                      icon: Icons.swap_horiz,
                      label: l10n.swapButton,
                      onTap: () => _openSwap(context),
                    ),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 24),

          // Tabs: Tokens / Activity. Only one list is rendered at a time
          // so each gets the dashboard's full width.
          _TabSwitcher(
            selected: _selectedTab,
            labels: [l10n.dashboardTabTokens, l10n.dashboardTabActivity],
            onChanged: (i) {
              setState(() => _selectedTab = i);
              if (i == 1) unawaited(store.refreshHistory());
            },
          ),
          const SizedBox(height: 12),
          if (_selectedTab == 0) ...[
            if (displayTokens.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    l10n.dashboardNoTokens,
                    style: const TextStyle(color: TibaneColors.textMuted),
                  ),
                ),
              )
            else
              ...displayTokens.map((h) {
                final isNativeRow = h.mint.endsWith('.NATIVE');
                final net = wallet.libwallet.currentNetwork;
                final isSolanaNative =
                    isNativeRow && net?.type == NetworkType.solana;
                // Defer to TokenIcon's wsolMint → sol.png branch for
                // Solana so it matches every other surface that shows
                // SOL. Other networks fall back to the bundled brand
                // logo since TokenIcon has no equivalent shortcut for
                // them.
                final assetPath = isNativeRow && !isSolanaNative && net != null
                    ? networkLogoAsset(net)
                    : null;
                final isEvmNative = isNativeRow && net?.type == NetworkType.evm;
                VoidCallback? openDetails;
                if (isSolanaNative) {
                  openDetails = () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const TokenDetailScreen(mint: wsolMint),
                    ),
                  );
                } else if (isEvmNative) {
                  openDetails = () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TokenDetailScreen.native(
                        holding: h,
                        nativeAssetPath: assetPath,
                      ),
                    ),
                  );
                } else if (!isNativeRow) {
                  openDetails = () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TokenDetailScreen(mint: h.mint),
                    ),
                  );
                }
                // The mint we hand to TokenIcon: for Solana-native, use
                // wsolMint so the bundled sol.png wins; otherwise pass
                // the row's mint untouched (synthetic `.NATIVE` sentinel
                // for non-Solana native, real on-chain mint for SPL).
                final iconMint = isSolanaNative ? wsolMint : h.mint;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: TibaneCard(
                    padding: const EdgeInsets.all(12),
                    onTap: openDetails,
                    child: Row(
                      children: [
                        TokenIcon(
                          imageUrl: h.imageUrl,
                          assetPath: assetPath,
                          mint: iconMint,
                          symbol: h.symbol.isNotEmpty ? h.symbol : h.name,
                          size: 44.85,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                h.symbol.isNotEmpty ? h.symbol : h.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16.1,
                                  color: TibaneColors.text,
                                ),
                              ),
                              if (h.name.isNotEmpty && h.name != h.symbol)
                                Text(
                                  h.name,
                                  style: monoStyle(
                                    fontSize: 13.2,
                                    color: TibaneColors.textMuted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              formatTokenAmount(
                                h.balance,
                                h.decimals,
                                displayDecimals: 4,
                              ),
                              style: monoStyle(fontSize: 18.4),
                            ),
                            if (h.valueUsd != null)
                              Text(
                                '\$${h.valueUsd!.toStringAsFixed(2)}',
                                style: monoStyle(
                                  fontSize: 13.2,
                                  color: TibaneColors.textMuted,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ] else ...[
            if (wallet.libwallet.currentNetwork?.type == NetworkType.bitcoin &&
                (wallet.libwallet.currentNetwork?.txHistoryProvider.isEmpty ??
                    true))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  l10n.activityHistoryLimited,
                  style: const TextStyle(color: TibaneColors.textMuted),
                ),
              ),
            if (store.loadingTxs)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(color: TibaneColors.orange),
                ),
              )
            else if (store.transactions.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    l10n.dashboardNoTransactions,
                    style: const TextStyle(color: TibaneColors.textMuted),
                  ),
                ),
              )
            else
              ...store.transactions.map(
                (tx) => _TransactionRow(
                  tx: tx,
                  myAddr: addr,
                  tokenInfo: _resolveTokenInfo(tx, wallet, store.holdings),
                ),
              ),
            if (store.historyHasMore)
              TextButton.icon(
                icon: store.loadingMoreHistory
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.expand_more),
                label: Text(l10n.activityLoadMore),
                onPressed: store.loadingMoreHistory
                    ? null
                    : () async {
                        try {
                          await store.loadMoreHistory();
                        } catch (error) {
                          if (context.mounted) showWalletError(context, error);
                        }
                      },
              ),
          ],
        ],
      ),
    );
  }

  /// Tokens to render in the Tokens tab. Always prepends a synthetic
  /// row for the active network's native asset (SOL / ETH / BNB /
  /// MATIC / BTC / LTC / DOGE) — even when the balance is zero — so
  /// the user can see and reach the network's native currency without
  /// reading the headline balance bar.
  ///
  /// The row's symbol/name/balance/decimals come from the matching
  /// `Asset` in `_assets` when it has loaded; otherwise the row falls
  /// back to the network's `currencySymbol` and a zero balance so the
  /// list isn't empty during the brief window before assets arrive.
  /// [BalancesStore] keeps its native SOL quote separate, so the SPL path
  /// never duplicates SOL.
  List<TokenHolding> _displayTokens(
    WalletService wallet,
    List<TokenHolding> holdings, {
    TokenHolding? nativeSolHolding,
  }) {
    final native = _nativeRowForCurrentNetwork(
      wallet,
      nativeSolHolding: nativeSolHolding,
    );
    final net = wallet.libwallet.currentNetwork;
    final isSolana = (net?.type ?? NetworkType.solana) == NetworkType.solana;

    if (isSolana) {
      // Solana: native SOL row + Jupiter-discovered SPL holdings (the list is
      // built with `excludeMint: wsolMint`, so SOL is never duplicated).
      if (native == null) return holdings;
      return [native, ...holdings];
    }

    // Non-Solana (EVM / Bitcoin): libwallet's getAssets is the source of
    // truth for token balances — Jupiter is Solana-only and `_holdings`
    // is empty here. Build a row per non-native asset on the active
    // network; the native asset is already rendered by `native`.
    final tokens = <TokenHolding>[];
    for (final a in wallet.assets) {
      if (net != null && !assetBelongsToNetwork(a, net)) continue;
      if (a.isNative) continue;
      tokens.add(_assetToHolding(a));
    }
    if (native == null) return tokens;
    return [native, ...tokens];
  }

  /// Convert a libwallet [Asset] (non-native token on the active
  /// network) into a [TokenHolding] row. Decimals come from
  /// `amount.exp` (authoritative); the fiat unit price is derived from
  /// the fiat total ÷ ui-balance when both are present.
  TokenHolding _assetToHolding(Asset a) {
    final balance = a.amount.value;
    final decimals = a.amount.exp;
    final divisor = BigInt.from(10).pow(decimals);
    final uiBalance = decimals > 0
        ? balance.toDouble() / divisor.toDouble()
        : balance.toDouble();
    final valueUsd = a.fiatAmount?.toDouble();
    final priceUsd = (uiBalance > 0 && valueUsd != null && valueUsd > 0)
        ? valueUsd / uiBalance
        : null;
    return TokenHolding(
      mint: a.tokenAddress ?? a.key,
      symbol: a.symbol,
      name: a.name.isNotEmpty ? a.name : a.symbol,
      imageUrl: null,
      balance: balance,
      decimals: decimals,
      uiBalance: uiBalance,
      priceUsd: priceUsd,
      valueUsd: (valueUsd != null && valueUsd > 0) ? valueUsd : null,
      priceChange24h: a.fiatQuote?.percentChange24h,
    );
  }

  TokenHolding? _nativeRowForCurrentNetwork(
    WalletService wallet, {
    TokenHolding? nativeSolHolding,
  }) {
    final net = wallet.libwallet.currentNetwork;
    if (net == null) return null;
    final mintKey = '${net.type.name}.${net.chainId}.NATIVE';

    if (net.type == NetworkType.solana && nativeSolHolding != null) {
      return TokenHolding(
        mint: mintKey,
        symbol: 'SOL',
        name: 'Solana',
        imageUrl: null,
        balance: nativeSolHolding.balance,
        decimals: 9,
        uiBalance: nativeSolHolding.uiBalance,
        priceUsd: nativeSolHolding.priceUsd,
        valueUsd: nativeSolHolding.valueUsd,
        priceChange24h: nativeSolHolding.priceChange24h,
      );
    }

    // Asset rows are what libwallet's getAssets returns; the native one
    // is whichever entry has the .NATIVE suffix on its key and matches
    // the active network. There is at most one per (account, network).
    Asset? nativeAsset;
    for (final a in wallet.assets) {
      if (a.isNative && assetBelongsToNetwork(a, net)) {
        nativeAsset = a;
        break;
      }
    }

    final ethWei = net.type == NetworkType.evm && net.chainId == '1'
        ? wallet.ethBalanceWei
        : null;
    if (ethWei != null) {
      final uiBalance = ethWei.toDouble() / 1e18;
      final assetUi = nativeAsset?.amount.toDouble() ?? 0;
      final fiatAmount = nativeAsset?.fiatAmount?.toDouble();
      final libwalletPrice =
          nativeAsset?.fiatQuote?.price ??
          (assetUi > 0 && fiatAmount != null ? fiatAmount / assetUi : null);
      final priceUsd = libwalletPrice != null && libwalletPrice > 0
          ? libwalletPrice
          : wallet.ethPriceUsd;
      return TokenHolding(
        mint: mintKey,
        symbol: 'ETH',
        name: net.name,
        imageUrl: null,
        balance: ethWei,
        decimals: 18,
        uiBalance: uiBalance,
        priceUsd: priceUsd,
        valueUsd: priceUsd == null ? null : uiBalance * priceUsd,
        priceChange24h: nativeAsset?.fiatQuote?.percentChange24h,
      );
    }

    if (nativeAsset != null) {
      final balance = nativeAsset.amount.value;
      final decimals = nativeAsset.amount.exp;
      final divisor = BigInt.from(10).pow(decimals);
      final uiBalance = decimals > 0
          ? balance.toDouble() / divisor.toDouble()
          : balance.toDouble();
      final libwalletValueUsd = nativeAsset.fiatAmount?.toDouble();
      final libwalletPriceUsd = nativeAsset.fiatQuote?.price;
      final priceUsd = libwalletPriceUsd != null && libwalletPriceUsd > 0
          ? libwalletPriceUsd
          : uiBalance > 0 && libwalletValueUsd != null && libwalletValueUsd > 0
          ? libwalletValueUsd / uiBalance
          : net.type == NetworkType.bitcoin
          ? wallet.bitcoinFamilyPriceUsd
          : null;
      final valueUsd = uiBalance == 0
          ? 0.0
          : libwalletValueUsd != null && libwalletValueUsd > 0
          ? libwalletValueUsd
          : priceUsd == null
          ? null
          : uiBalance * priceUsd;
      return TokenHolding(
        mint: mintKey,
        symbol: nativeAsset.symbol.isNotEmpty
            ? nativeAsset.symbol
            : net.currencySymbol,
        name: nativeAsset.name.isNotEmpty ? nativeAsset.name : net.name,
        imageUrl: null,
        balance: balance,
        decimals: decimals,
        uiBalance: uiBalance,
        priceUsd: priceUsd,
        valueUsd: valueUsd,
        priceChange24h: nativeAsset.fiatQuote?.percentChange24h,
      );
    }

    // Solana fallback: WalletService caches the SOL balance separately
    // (refreshBalances populates it before getAssets returns), so we
    // can render a populated row even on a cold dashboard mount.
    if (net.type == NetworkType.solana) {
      final uiBalance = wallet.solBalance.toDouble() / 1e9;
      final valueUsd = wallet.solFiatUsd;
      final priceUsd = uiBalance > 0 && valueUsd > 0
          ? valueUsd / uiBalance
          : null;
      return TokenHolding(
        mint: mintKey,
        symbol: 'SOL',
        name: 'Solana',
        imageUrl: null,
        balance: wallet.solBalance,
        decimals: 9,
        uiBalance: uiBalance,
        priceUsd: priceUsd,
        valueUsd: valueUsd > 0 ? valueUsd : null,
      );
    }

    // No native Asset yet (assets haven't loaded) and not Solana — render
    // a zero-balance placeholder so the network's native ticker is at
    // least visible while we wait.
    return TokenHolding(
      mint: mintKey,
      symbol: net.currencySymbol.isNotEmpty ? net.currencySymbol : 'NATIVE',
      name: net.name.isNotEmpty ? net.name : 'Native',
      imageUrl: null,
      balance: BigInt.zero,
      decimals: 0,
      uiBalance: 0,
    );
  }

  /// Resolve display info (symbol + icon) for a transaction's asset by
  /// joining `tx.asset` against the data we've already loaded: the
  /// libwallet `Asset` list for native + tracked tokens, and Jupiter
  /// `_holdings` for everything else. Falls back to the active
  /// network's native ticker when nothing matches (libwallet's tx
  /// table is shared across networks and the asset key may reference
  /// a chain we haven't fetched assets for yet).
  _TxTokenInfo _resolveTokenInfo(
    Transaction tx,
    WalletService wallet,
    List<TokenHolding> holdings,
  ) {
    final assetKey = tx.asset;
    final lastDot = assetKey.lastIndexOf('.');
    final tail = lastDot >= 0 ? assetKey.substring(lastDot + 1) : assetKey;
    final isNative = tail == 'NATIVE';
    // Native Solana → swap in wSOL's mint so TokenIcon's
    // `mint == wsolMint` branch picks up the bundled sol.png.
    // Without this the row would land on the letter-S placeholder
    // since libwallet doesn't carry a logo URL for native assets.
    final isNativeSol = isNative && assetKey.startsWith('solana.');

    for (final a in wallet.assets) {
      if (a.key == assetKey) {
        return _TxTokenInfo(
          symbol: a.symbol,
          mint: isNativeSol ? wsolMint : (isNative ? null : a.tokenAddress),
          imageUrl: null,
          isNative: isNative,
        );
      }
    }
    if (!isNative) {
      for (final h in holdings) {
        if (h.mint == tail) {
          return _TxTokenInfo(
            symbol: h.symbol.isNotEmpty ? h.symbol : h.name,
            mint: h.mint,
            imageUrl: h.imageUrl,
            isNative: false,
          );
        }
      }
    }
    final net = wallet.libwallet.currentNetwork;
    return _TxTokenInfo(
      symbol: isNative
          ? (net?.currencySymbol.isNotEmpty == true ? net!.currencySymbol : '')
          : '',
      mint: isNativeSol ? wsolMint : (isNative ? null : tail),
      imageUrl: null,
      isNative: isNative,
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
    final l10n = context.l10n;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: TibaneColors.black,
          appBar: AppBar(title: Text(l10n.swapButton)),
          body: SwapScreen(
            initialInputMint: inputMint ?? wsolMint,
            initialOutputMint: outputMint ?? chiefPussyMint,
          ),
        ),
      ),
    );
  }
}

class _PortfolioPerformanceLine extends StatelessWidget {
  final PortfolioPerformance24h performance;

  const _PortfolioPerformanceLine({required this.performance});

  @override
  Widget build(BuildContext context) {
    final positive = performance.amountUsd >= 0;
    final color = positive ? TibaneColors.success : TibaneColors.error;
    final percent = _signedNumber(performance.percent, suffix: '%');
    final amount = NumberFormat.currency(
      locale: 'en_US',
      symbol: r'$',
      decimalDigits: 2,
    ).format(performance.amountUsd.abs());
    final signedAmount = '${positive ? '+' : '-'}$amount';

    return Semantics(
      label: context.l10n.dashboardPnl24hSemantics(percent, signedAmount),
      child: Transform.translate(
        offset: const Offset(-3, 0),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            key: const Key('wallet-pnl-content'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color.withValues(alpha: 0.35)),
                ),
                child: Text(
                  percent,
                  style: monoStyle(
                    fontSize: 11,
                    color: color,
                  ).copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                amount,
                style: monoStyle(
                  fontSize: 12,
                  color: color,
                ).copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _signedNumber(double value, {String suffix = ''}) {
  final sign = value >= 0 ? '+' : '-';
  final absolute = value.abs();
  final decimals = absolute >= 10 ? 1 : 2;
  return '$sign${absolute.toStringAsFixed(decimals)}$suffix';
}

class _TabSwitcher extends StatelessWidget {
  final int selected;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  const _TabSwitcher({
    required this.selected,
    required this.labels,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('wallet-activity-tabs'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: TibaneColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TibaneColors.border),
      ),
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++)
            Expanded(
              child: Material(
                color: i == selected ? TibaneColors.orange : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onChanged(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: SizedBox(
                      height:
                          MediaQuery.textScalerOf(context).scale(13) *
                          (DefaultTextStyle.of(context).style.height ?? 1),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          labels[i],
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13 * 1.2,
                            height:
                                (DefaultTextStyle.of(context).style.height ??
                                    1) /
                                1.2,
                            color: i == selected
                                ? TibaneColors.black
                                : TibaneColors.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Resolved display info for a transaction row's asset — symbol +
/// optional logo. Built once per render by [_resolveTokenInfo] and
/// passed into [_TransactionRow] so the row can show the token's
/// ticker and icon instead of just an up/down arrow.
class _TxTokenInfo {
  final String symbol;
  final String? mint;
  final String? imageUrl;
  final bool isNative;

  const _TxTokenInfo({
    required this.symbol,
    required this.mint,
    required this.imageUrl,
    required this.isNative,
  });
}

class _TransactionRow extends StatelessWidget {
  final Transaction tx;
  final String myAddr;
  final _TxTokenInfo tokenInfo;

  const _TransactionRow({
    required this.tx,
    required this.myAddr,
    required this.tokenInfo,
  });

  bool get _isSend => tx.asset.startsWith('evm.')
      ? tx.from.toLowerCase() == myAddr.toLowerCase()
      : tx.from == myAddr;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final activity = context.watch<BalancesStore>().activityFor(tx);
    final isSolana = tx.asset.startsWith('solana.');
    final kind =
        activity?.kind ??
        (isSolana
            ? ActivityKind.transaction
            : _isSend
            ? ActivityKind.sent
            : ActivityKind.received);
    final label = activity?.failed == true
        ? l10n.activityFailed
        : switch (kind) {
            ActivityKind.swap => l10n.swapButton,
            ActivityKind.sent => l10n.dashboardTxSent,
            ActivityKind.received => l10n.dashboardTxReceived,
            ActivityKind.transaction => l10n.labelTransaction,
          };
    final counterparty =
        kind == ActivityKind.swap || kind == ActivityKind.transaction
        ? tx.hash ?? tx.id
        : kind == ActivityKind.sent
        ? activity?.recipient ?? tx.to
        : activity?.sender ?? tx.from;
    final amt = tx.amount;
    final amountStr = amt != null && !amt.isMax
        ? formatActivityAmount(amt.value.abs(), amt.exp, maxDecimals: 4)
        : '';
    final fiatStr = !isSolana && tx.fiatAmount != null
        ? '\$${tx.fiatAmount!.toDouble().toStringAsFixed(2)}'
        : null;
    final created = (activity?.created ?? tx.created)?.toLocal();
    final timeStr = created != null
        ? '${created.month}/${created.day} ${created.hour}:${created.minute.toString().padLeft(2, '0')}'
        : '';
    final amountColor = _isSend ? TibaneColors.error : TibaneColors.cyan;
    final amountLine = StringBuffer(_isSend ? '-' : '+')..write(amountStr);
    if (tokenInfo.symbol.isNotEmpty) {
      amountLine
        ..write(' ')
        ..write(tokenInfo.symbol);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TibaneCard(
        key: Key('activity-transaction-${tx.id}'),
        padding: const EdgeInsets.all(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TransactionDetailsScreen(
              transaction: tx,
              owner: myAddr,
              network: context.read<WalletService>().libwallet.currentNetwork,
            ),
          ),
        ),
        child: Row(
          children: [
            if (kind == ActivityKind.swap)
              Container(
                key: Key('activity-swap-icon-${tx.id}'),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: TibaneColors.orange.withValues(alpha: 0.1),
                ),
                child: const Icon(
                  Icons.swap_horiz,
                  size: 24,
                  color: TibaneColors.orange,
                ),
              )
            else if (kind == ActivityKind.transaction)
              Icon(
                Icons.receipt_long_outlined,
                size: 32,
                color: TibaneColors.orange,
              )
            else
              Stack(
                clipBehavior: Clip.none,
                children: [
                  TokenIcon(
                    imageUrl: tokenInfo.imageUrl,
                    mint: tokenInfo.mint ?? '',
                    symbol: tokenInfo.symbol,
                    size: 32,
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: TibaneColors.card,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        kind == ActivityKind.sent
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: 12,
                        color: amountColor,
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13 * 1.15,
                    ),
                  ),
                  Text(
                    shortenAddress(counterparty),
                    style: monoStyle(
                      fontSize: 11,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (activity != null)
                    for (final change in [
                      ...activity.changes.where((c) => c.amount.isNegative),
                      ...activity.changes.where((c) => !c.amount.isNegative),
                    ])
                      ActivityTokenAmount(change: change, compact: true)
                  else if (!isSolana)
                    Text(
                      amountLine.toString(),
                      style: TextStyle(
                        color: amountColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  if (fiatStr != null)
                    Text(
                      fiatStr,
                      style: monoStyle(
                        fontSize: 11,
                        color: TibaneColors.textMuted,
                      ),
                    ),
                  if (timeStr.isNotEmpty)
                    Text(
                      timeStr,
                      style: monoStyle(
                        fontSize: 10,
                        color: TibaneColors.textDim,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
