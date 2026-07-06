import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show Asset, NetworkType, Transaction;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../constants/solana_constants.dart';
import '../../services/balances_store.dart';
import '../../services/jupiter_service.dart';
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
    final wallet = context.watch<WalletService>();
    final store = context.watch<BalancesStore>();
    final addr = wallet.publicKey ?? '';

    return RefreshIndicator(
      // Pull-to-refresh: the store forces fresh balances + on-chain SPL
      // discovery + a tx-history backfill sweep, then reloads holdings + tx.
      onRefresh: store.refresh,
      color: TibaneColors.orange,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Total portfolio balance (SOL fiat from libwallet + sum of
          // every on-chain SPL holding's USD value) on top, with the
          // native SOL amount underneath as a secondary line.
          Center(
            child: Builder(
              builder: (context) {
                final solFiat = wallet.assets
                    .where((a) => a.isNative)
                    .fold<double>(
                      0,
                      (sum, a) => sum + (a.fiatAmount?.toDouble() ?? 0),
                    );
                // Sum every non-native displayed token's USD value. On
                // Solana these are the Jupiter holdings; on EVM/BTC they
                // are the libwallet asset rows — keeping the headline in
                // step with the token list on every chain.
                final tokensFiat = _displayTokens(wallet, store.holdings)
                    .where((h) => !h.mint.endsWith('.NATIVE'))
                    .fold<double>(0, (sum, h) => sum + (h.valueUsd ?? 0));
                final totalUsd = solFiat + tokensFiat;
                // Express the dollar total in SOL when we have enough
                // signal to compute the SOL price (native fiat ÷ native
                // ui-balance). Falls back to silence on non-Solana
                // networks or when balances haven't loaded yet rather
                // than printing a misleading 0.
                final solUi = wallet.solBalance.toDouble() / 1e9;
                final solPriceUsd = (solFiat > 0 && solUi > 0)
                    ? solFiat / solUi
                    : null;
                final totalInSol = solPriceUsd != null
                    ? totalUsd / solPriceUsd
                    : null;
                return Column(
                  children: [
                    Text(
                      '\$${totalUsd.toStringAsFixed(2)}',
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (totalInSol != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${totalInSol.toStringAsFixed(4)} SOL',
                        style: monoStyle(
                          fontSize: 13,
                          color: TibaneColors.textMuted,
                        ),
                      ),
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
                  _ActionButton(
                    icon: Icons.arrow_downward,
                    label: 'Receive',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ReceiveScreen()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _ActionButton(
                    icon: Icons.arrow_upward,
                    label: 'Send',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SendScreen()),
                    ),
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
            },
          ),
          const SizedBox(height: 24),

          // Tabs: Tokens / Activity. Only one list is rendered at a time
          // so each gets the dashboard's full width.
          _TabSwitcher(
            selected: _selectedTab,
            labels: const ['Tokens', 'Activity'],
            onChanged: (i) => setState(() => _selectedTab = i),
          ),
          const SizedBox(height: 12),
          if (_selectedTab == 0) ...[
            if (_displayTokens(wallet, store.holdings).isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'No tokens yet',
                    style: TextStyle(color: TibaneColors.textMuted),
                  ),
                ),
              )
            else
              ..._displayTokens(wallet, store.holdings).map((h) {
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
                // Resolve the on-chain mint to push to TokenDetailScreen.
                // Native rows carry a synthetic ".NATIVE" sentinel that
                // Helius DAS doesn't understand — substitute wSOL for
                // Solana; leave EVM/BTC native rows non-tappable since
                // there's no equivalent analytics surface for them.
                String? detailMint;
                if (isNativeRow) {
                  if (isSolanaNative) detailMint = wsolMint;
                } else {
                  detailMint = h.mint;
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
                    onTap: detailMint == null
                        ? null
                        : () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  TokenDetailScreen(mint: detailMint!),
                            ),
                          ),
                    child: Row(
                      children: [
                        TokenIcon(
                          imageUrl: h.imageUrl,
                          assetPath: assetPath,
                          mint: iconMint,
                          symbol: h.symbol.isNotEmpty ? h.symbol : h.name,
                          size: 32,
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
                                  fontSize: 14,
                                  color: TibaneColors.text,
                                ),
                              ),
                              if (h.name.isNotEmpty && h.name != h.symbol)
                                Text(
                                  h.name,
                                  style: monoStyle(
                                    fontSize: 11,
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
                              style: monoStyle(fontSize: 13),
                            ),
                            if (h.valueUsd != null)
                              Text(
                                '\$${h.valueUsd!.toStringAsFixed(2)}',
                                style: monoStyle(
                                  fontSize: 11,
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
                    'No transactions yet',
                    style: TextStyle(color: TibaneColors.textMuted),
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
  /// `_holdings` is built with `excludeMint: wsolMint`, so the SPL
  /// path never duplicates SOL.
  List<TokenHolding> _displayTokens(
    WalletService wallet,
    List<TokenHolding> holdings,
  ) {
    final native = _nativeRowForCurrentNetwork(wallet);
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
      if (net != null && a.network != net.id) continue;
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
    );
  }

  TokenHolding? _nativeRowForCurrentNetwork(WalletService wallet) {
    final net = wallet.libwallet.currentNetwork;
    if (net == null) return null;
    final mintKey = '${net.type.name}.${net.chainId}.NATIVE';

    // Asset rows are what libwallet's getAssets returns; the native one
    // is whichever entry has the .NATIVE suffix on its key and matches
    // the active network. There is at most one per (account, network).
    Asset? nativeAsset;
    for (final a in wallet.assets) {
      if (a.isNative && a.network == net.id) {
        nativeAsset = a;
        break;
      }
    }

    if (nativeAsset != null) {
      final balance = nativeAsset.amount.value;
      final decimals = nativeAsset.amount.exp;
      final divisor = BigInt.from(10).pow(decimals);
      final uiBalance = decimals > 0
          ? balance.toDouble() / divisor.toDouble()
          : balance.toDouble();
      final valueUsd = nativeAsset.fiatAmount?.toDouble();
      final priceUsd = (uiBalance > 0 && valueUsd != null && valueUsd > 0)
          ? valueUsd / uiBalance
          : null;
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
        valueUsd: (valueUsd != null && valueUsd > 0) ? valueUsd : null,
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
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
                    child: Text(
                      labels[i],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: i == selected
                            ? TibaneColors.black
                            : TibaneColors.textMuted,
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

  bool get _isSend => tx.from == myAddr;

  @override
  Widget build(BuildContext context) {
    final counterparty = _isSend ? tx.to : tx.from;
    final amt = tx.amount;
    final amountStr = amt != null && !amt.isMax
        ? formatAmountTrimmed(amt.value, amt.exp)
        : '';
    final fiatStr = tx.fiatAmount != null
        ? '\$${tx.fiatAmount!.toDouble().toStringAsFixed(2)}'
        : null;
    final timeStr = tx.created != null
        ? '${tx.created!.month}/${tx.created!.day} ${tx.created!.hour}:${tx.created!.minute.toString().padLeft(2, '0')}'
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
        padding: const EdgeInsets.all(12),
        onTap: tx.url != null && tx.url!.isNotEmpty
            ? () => launchUrl(Uri.parse(tx.url!))
            : null,
        child: Row(
          children: [
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
                      _isSend ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 12,
                      color: amountColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isSend ? 'Sent' : 'Received',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
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
                    style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
