import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../models/staking_pool.dart';
import '../services/favorites_service.dart';
import '../services/rpc_service.dart';
import '../services/staker_instructions.dart';
import '../theme/tibane_theme.dart';
import '../widgets/tibane_card.dart';
import '../widgets/token_search.dart';
import 'staking/staking_detail_screen.dart';

/// Landing screen for the "Token Info" feature: lists the user's
/// favorited tokens and offers a search field for unknown mints /
/// tickers. Each tap / search submission pushes a
/// [StakingDetailScreen] route for the matching pool.
class TokenFavoritesScreen extends StatefulWidget {
  const TokenFavoritesScreen({super.key});

  @override
  State<TokenFavoritesScreen> createState() => _TokenFavoritesScreenState();
}

class _TokenFavoritesScreenState extends State<TokenFavoritesScreen> {
  final _rpc = RpcService();
  bool _loading = false;

  @override
  void dispose() {
    _rpc.dispose();
    super.dispose();
  }

  /// Resolve [mintInput] to a staking pool and push the staking detail
  /// screen. When [favorite] is provided, its display metadata (name,
  /// symbol, image) is grafted onto the pool object so the staking
  /// screen doesn't flash a bare "Pool" title before its own refresh
  /// populates the fields.
  Future<void> _openPool(String mintInput, {FavoriteToken? favorite}) async {
    final mint = mintInput.trim();
    if (mint.length < 32 || _loading) return;
    setState(() => _loading = true);
    try {
      final poolAddr = derivePoolPDA(mint);
      final data = await _rpc.getAccountInfo(poolAddr);
      if (!mounted) return;
      if (data == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No staking pool found for this token')),
        );
        return;
      }
      final pool = StakingPool.deserialize(poolAddr, data);
      if (pool == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read staking pool data')),
        );
        return;
      }
      if (favorite != null) {
        pool.tokenName = favorite.name;
        pool.tokenSymbol = favorite.symbol;
        pool.tokenImage = favorite.imageUrl;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => StakingDetailScreen(pool: pool)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load pool: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final favs = context.watch<FavoritesService>();

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Tokens')),
      body: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: TokenSearch(
          onResultSelected: (r) => _openPool(
            r.mint,
            favorite: FavoriteToken(
              mint: r.mint,
              name: r.name,
              symbol: r.symbol,
              imageUrl: r.imageUrl,
            ),
          ),
          onMintSubmitted: (mint) => _openPool(mint),
          emptyBody: favs.favorites.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.star_border,
                        size: 48,
                        color: TibaneColors.textDim,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No favorite tokens yet',
                        style: TextStyle(color: TibaneColors.textMuted),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Search for a token and tap the star to add it',
                        style:
                            monoStyle(fontSize: 11, color: TibaneColors.textDim),
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
                      onTap: () => _openPool(fav.mint, favorite: fav),
                      onRemove: () => favs.toggle(fav.mint),
                    );
                  },
                ),
        ),
      ),
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
                        errorBuilder: (_, e, s) => const Icon(
                          Icons.token,
                          size: 20,
                          color: TibaneColors.textDim,
                        ),
                      ),
                    )
                  : const Icon(
                      Icons.token,
                      size: 20,
                      color: TibaneColors.textDim,
                    ),
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
