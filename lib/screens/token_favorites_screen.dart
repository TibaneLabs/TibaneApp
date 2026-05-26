import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../services/favorites_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/tibane_card.dart';
import '../widgets/token_search.dart';
import 'token_detail_screen.dart';

/// Landing screen for the "Token Info" feature: lists the user's
/// favorited tokens and offers a search field for unknown mints /
/// tickers. Each tap / search submission pushes a
/// [TokenDetailScreen] route — this screen never renders token
/// analytics inline.
class TokenFavoritesScreen extends StatefulWidget {
  const TokenFavoritesScreen({super.key});

  @override
  State<TokenFavoritesScreen> createState() => _TokenFavoritesScreenState();
}

class _TokenFavoritesScreenState extends State<TokenFavoritesScreen> {
  /// Push the [TokenDetailScreen] for [mintInput]. Wrapped in async
  /// only so [TokenSearch.onMintSubmitted] can await the push and
  /// drive its suffix spinner for the brief frame between tap and
  /// route transition — the actual navigation is synchronous.
  Future<void> _openToken(String mintInput) async {
    final mint = mintInput.trim();
    if (mint.length < 32) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TokenDetailScreen(mint: mint)),
    );
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
          onResultSelected: (r) => _openToken(r.mint),
          onMintSubmitted: _openToken,
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
                      onTap: () => _openToken(fav.mint),
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
