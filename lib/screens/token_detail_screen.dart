import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show NetworkType;
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../l10n/l10n.dart';
import '../models/staking_pool.dart';
import '../models/token_account.dart';
import '../services/chiefstaker_api.dart';
import '../services/favorites_service.dart';
import '../services/jupiter_service.dart';
import '../services/rpc_service.dart';
import '../services/staker_instructions.dart';
import '../services/uk_compliance_service.dart';
import '../services/wallet/swap_asset.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/gradient_button.dart';
import '../widgets/tibane_card.dart';
import '../widgets/token_icon.dart';
import '../widgets/tx_success.dart';
import 'fee_sharing_screen.dart';
import 'staking/staking_detail_screen.dart';
import 'swap_screen.dart';
import 'wallet/receive_screen.dart';
import 'wallet/send_screen.dart';
import 'wallet/widgets/wallet_action_button.dart';
import '../utils/log.dart';
import '../utils/wallet_error.dart';
import '../utils/context_extensions.dart';

/// Read-only analytics view for a single SPL token: metadata, supply,
/// market cap, top holders, optional staking-pool + fee-sharing entry
/// points. Pushed as its own route by
/// [TokenFavoritesScreen] and by deep-link / token-row taps elsewhere
/// in the app, so it owns its [Scaffold] and [AppBar] — no caller
/// wrapping required.
class TokenDetailScreen extends StatefulWidget {
  final String mint;
  final TokenHolding? nativeHolding;
  final String? nativeAssetPath;

  const TokenDetailScreen({super.key, required this.mint})
    : nativeHolding = null,
      nativeAssetPath = null;

  TokenDetailScreen.native({
    super.key,
    required TokenHolding holding,
    this.nativeAssetPath,
  }) : mint = holding.mint,
       nativeHolding = holding;

  @override
  State<TokenDetailScreen> createState() => _TokenDetailScreenState();
}

class _TokenDetailScreenState extends State<TokenDetailScreen> {
  final _rpc = RpcService();
  TokenMetadata? _token;
  List<TokenHolder> _holders = [];
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
    final nativeHolding = widget.nativeHolding;
    if (nativeHolding != null) {
      setState(() {
        _token = TokenMetadata(
          mint: nativeHolding.mint,
          name: nativeHolding.name,
          symbol: nativeHolding.symbol,
          decimals: nativeHolding.decimals,
          pricePerToken: nativeHolding.priceUsd,
        );
        _holders = const [];
        _userBalance = nativeHolding.balance;
        _loading = false;
      });
      return;
    }
    if (widget.mint.length < 32) {
      setState(() {
        _error = context.l10n.tokenDetailInvalidMint;
        _loading = false;
      });
      return;
    }
    if (widget.mint == wsolMint) {
      setState(() {
        _token = TokenMetadata(
          mint: wsolMint,
          name: 'Solana',
          symbol: 'SOL',
          decimals: 9,
        );
        _holders = const [];
        _loading = false;
      });
      _backfillPriceIfMissing();
      _loadUserBalance();
      return;
    }
    try {
      final results = await Future.wait([
        _rpc.getAsset(widget.mint),
        _rpc.getTopHolders(widget.mint, limit: 10),
      ]);
      if (!mounted) return;
      setState(() {
        _token = results[0] as TokenMetadata?;
        _holders = results[1] as List<TokenHolder>;
        _loading = false;
        if (_token == null) {
          _error = context.l10n.tokenNotFound;
        }
      });
      _checkStakingPool();
      _backfillPriceIfMissing();
      _loadUserBalance();
    } catch (e) {
      logError('[token-detail._loadToken] error: $e');
      if (!mounted) return;
      setState(() {
        _error = walletErrorMessageForContext(context, e);
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
      appBar: AppBar(title: Text(context.l10n.tokenDetailTitle)),
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
              stakingPool: _stakingPool,
              userBalance: _userBalance,
              nativeAssetPath: widget.nativeAssetPath,
              onRefresh: _loadToken,
            ),
    );
  }
}

class _TokenDetails extends StatelessWidget {
  final TokenMetadata token;
  final List<TokenHolder> holders;
  final StakingPool? stakingPool;
  final BigInt? userBalance;
  final String? nativeAssetPath;
  final Future<void> Function() onRefresh;

  const _TokenDetails({
    required this.token,
    required this.holders,
    required this.onRefresh,
    this.stakingPool,
    this.userBalance,
    this.nativeAssetPath,
  });

  @override
  Widget build(BuildContext context) {
    final isNative = _isNativeToken(token);
    return RefreshIndicator(
      color: TibaneColors.orange,
      onRefresh: onRefresh,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TokenHeader(
              token: token,
              nativeAssetPath: nativeAssetPath,
              isNative: isNative,
            ),
            const SizedBox(height: 12),

            _TokenActions(token: token, userBalance: userBalance),

            if (isNative && token.pricePerToken != null) ...[
              const SizedBox(height: 20),
              _TokenPriceCard(token: token),
            ],

            if (!isNative) ...[
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
                          builder: (_) =>
                              StakingDetailScreen(pool: stakingPool!),
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
                        Expanded(
                          child: Text(
                            context.l10n.tokenDetailStakingPool,
                            style: const TextStyle(
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
                            context.l10n.tokenDetailStakingPoolActive,
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
                    label: context.l10n.tokenDetailFeeSharing,
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
            ],
          ],
        ),
      ),
    );
  }
}

class _TokenHeader extends StatelessWidget {
  final TokenMetadata token;
  final String? nativeAssetPath;
  final bool isNative;

  const _TokenHeader({
    required this.token,
    required this.isNative,
    this.nativeAssetPath,
  });

  @override
  Widget build(BuildContext context) {
    final favs = context.watch<FavoritesService>();
    final isFav = favs.isFavorite(token.mint);

    return TibaneCard(
      child: Column(
        children: [
          Row(
            children: [
              TokenIcon(
                imageUrl: token.imageUrl,
                assetPath: nativeAssetPath,
                mint: token.mint,
                symbol: token.symbol ?? token.name ?? '',
                size: 64,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        token.name ?? context.l10n.tokenDetailUnknownToken,
                        maxLines: 1,
                        style: context.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
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
                    if (!isNative) ...[
                      const SizedBox(height: 7),
                      InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: token.mint));
                          context.showSnackBar(
                            SnackBar(
                              content: Text(
                                context.l10n.tokenDetailMintAddressCopied,
                              ),
                            ),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  _shortTokenAddress(token.mint),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: monoStyle(
                                    fontSize: 14,
                                    color: TibaneColors.textMuted,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.copy,
                                size: 18,
                                color: TibaneColors.textMuted,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
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
            ],
          ),
        ],
      ),
    );
  }
}

/// Receive / Send / Swap using the same component as the wallet dashboard.
class _TokenActions extends StatelessWidget {
  final TokenMetadata token;
  final BigInt? userBalance;

  const _TokenActions({required this.token, this.userBalance});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isUk = context.watch<UkComplianceService>().isUk;
    final isNative = _isNativeToken(token);
    final isNativeSol = token.mint == wsolMint;
    final network = context.read<WalletService>().libwallet.currentNetwork;
    final nativeMint = nativeSwapMint(network?.type ?? NetworkType.solana);
    final nativeSymbol = nativeMint == wsolMint
        ? 'SOL'
        : (network?.currencySymbol ?? 'ETH');
    final nativeName = nativeMint == wsolMint
        ? 'Solana'
        : (network?.name ?? 'Ethereum');
    final canSend = userBalance != null && userBalance! > BigInt.zero;
    return Row(
      children: [
        WalletActionButton(
          label: l10n.receiveTitle,
          icon: Icons.arrow_downward,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const ReceiveScreen())),
        ),
        const SizedBox(width: 12),
        WalletActionButton(
          label: l10n.dashboardSend,
          icon: Icons.arrow_upward,
          onTap: canSend
              ? () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => isNative
                        ? const SendScreen()
                        : SendScreen(
                            mint: token.mint,
                            symbol: token.symbol,
                            decimals: token.decimals,
                          ),
                  ),
                )
              : null,
        ),
        if (!isUk) ...[
          const SizedBox(width: 12),
          WalletActionButton(
            label: l10n.swapButton,
            icon: Icons.swap_horiz,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: TibaneColors.black,
                  appBar: AppBar(title: Text(l10n.swapButton)),
                  body: isNative
                      ? SwapScreen(
                          initialInputMint: isNativeSol
                              ? wsolMint
                              : evmNativeSwapMint,
                        )
                      : SwapScreen(
                          initialInputMint: token.mint,
                          initialOutputMint: nativeMint,
                          initialOutputSymbol: nativeSymbol,
                          initialOutputName: nativeName,
                          initialOutputDecimals: nativeMint == wsolMint
                              ? 9
                              : 18,
                        ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SupplySection extends StatelessWidget {
  final TokenMetadata token;

  const _SupplySection({required this.token});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.tokenDetailSupplySection,
          style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StatCard(
                label: l10n.labelTotalSupply,
                value: formatTokenAmount(token.supply, token.decimals),
                icon: Icons.pie_chart,
              ),
            ),
            if (token.pricePerToken != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: StatCard(
                  label: l10n.tokenDetailMarketCap,
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
            label: l10n.tokenDetailBurned,
            value: formatTokenAmount(token.burned, token.decimals),
            valueColor: TibaneColors.orange,
            icon: Icons.local_fire_department,
          ),
        ],
        if (token.pricePerToken != null) ...[
          const SizedBox(height: 8),
          _TokenPriceCard(token: token),
        ],
      ],
    );
  }
}

class _TokenPriceCard extends StatelessWidget {
  final TokenMetadata token;

  const _TokenPriceCard({required this.token});

  @override
  Widget build(BuildContext context) {
    final price = token.pricePerToken;
    if (price == null) return const SizedBox.shrink();

    return TibaneCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Icon(Icons.attach_money, size: 20, color: TibaneColors.gold),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '\$${price.toStringAsFixed(price < 0.01 ? 8 : 4)}',
              style: const TextStyle(
                color: TibaneColors.text,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
          ),
          Text(
            context.l10n.tokenDetailPerToken,
            style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
          ),
        ],
      ),
    );
  }
}

bool _isNativeToken(TokenMetadata token) =>
    token.mint == wsolMint || token.mint.endsWith('.NATIVE');

String _shortTokenAddress(String address) {
  if (address.length <= 13) return address;
  return '${address.substring(0, 5)}...${address.substring(address.length - 5)}';
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
    final visibleHolders = holders.take(10).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.tokenDetailTopHolders,
          style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 12),
        TibaneCard(
          child: Column(
            children: [
              for (var i = 0; i < visibleHolders.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: TibaneColors.border),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 36,
                        child: Text(
                          '#${i + 1}',
                          maxLines: 1,
                          softWrap: false,
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
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => openExplorerUrl(
                            context,
                            solscanAccountUrl(visibleHolders[i].address),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    shortenAddress(
                                      visibleHolders[i].address,
                                      chars: 6,
                                    ),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: monoStyle(
                                      fontSize: 12,
                                      color: TibaneColors.orange,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.open_in_new,
                                  size: 12,
                                  color: TibaneColors.orange,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Text(
                        '${visibleHolders[i].percentage.toStringAsFixed(2)}%',
                        style: monoStyle(
                          fontSize: 12,
                          color: visibleHolders[i].percentage > 5
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
        const SizedBox(height: 12),
        SecondaryButton(
          label: context.l10n.tokenDetailAllHolders,
          icon: Icons.open_in_new,
          expanded: true,
          onPressed: () => openExplorerUrl(
            context,
            solscanTokenUrl(token.mint, holders: true),
          ),
        ),
      ],
    );
  }
}
