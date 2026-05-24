import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../models/staking_pool.dart';
import '../services/favorites_service.dart';
import '../services/jupiter_service.dart';
import '../services/rpc_service.dart';
import '../services/staker_instructions.dart';
import '../theme/tibane_theme.dart';
import '../widgets/tibane_card.dart';
import 'staking/staking_detail_screen.dart';

/// Landing screen for the "Token Info" feature: lists the user's
/// favorited tokens and offers a search field for unknown mints. Each
/// tap / search submission pushes a [TokenDetailScreen] route — this
/// screen never renders token analytics inline.
class TokenFavoritesScreen extends StatefulWidget {
  const TokenFavoritesScreen({super.key});

  @override
  State<TokenFavoritesScreen> createState() => _TokenFavoritesScreenState();
}

class _TokenFavoritesScreenState extends State<TokenFavoritesScreen> {
  final _searchController = TextEditingController();
  final _rpc = RpcService();
  final _jupiter = JupiterService();
  bool _loading = false;

  // Live ticker/name search state. The favorites list is hidden while
  // _query is non-empty so the user is always looking at what their
  // input would resolve to.
  String _query = '';
  Timer? _debounce;
  bool _searching = false;
  List<TokenSearchResult> _results = const [];
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _rpc.dispose();
    _jupiter.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final value = _searchController.text.trim();
    if (value == _query) return;
    setState(() => _query = value);
    _debounce?.cancel();
    if (value.isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    // Mint-shaped input is handled by the submit / arrow path
    // (direct pool lookup) — no need to hit the Jupiter search.
    if (value.length >= 32 && value.length <= 44) return;
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _runSearch(value),
    );
  }

  Future<void> _runSearch(String query) async {
    final mySeq = ++_searchSeq;
    setState(() => _searching = true);
    final results = await _jupiter.searchTokens(query);
    if (!mounted || mySeq != _searchSeq) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  /// Resolve [mintInput] to a staking pool and push the staking detail
  /// screen. When [favorite] is provided, its display metadata (name,
  /// symbol, image) is grafted onto the pool object so the staking
  /// screen doesn't flash a bare "Pool" title before its own refresh
  /// populates the fields.
  /// Pick the right body for the current state — favorites list when
  /// the search field is empty, otherwise the search results / empty
  /// / "type more" placeholder.
  Widget _buildBody(FavoritesService favs) {
    if (_query.isEmpty) {
      if (favs.favorites.isEmpty) {
        return Center(
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
                style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
              ),
            ],
          ),
        );
      }
      return ListView.builder(
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
      );
    }
    // Mint-shaped input — skip search results, the submit / arrow path
    // will resolve the pool directly.
    if (_query.length >= 32 && _query.length <= 44) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Press Enter to open the staking pool for this mint.',
            textAlign: TextAlign.center,
            style: TextStyle(color: TibaneColors.textMuted),
          ),
        ),
      );
    }
    if (_searching && _results.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: TibaneColors.orange),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No tokens match "$_query".',
            textAlign: TextAlign.center,
            style: TextStyle(color: TibaneColors.textMuted),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final r = _results[index];
        return _SearchResultTile(
          result: r,
          isFavorite: favs.isFavorite(r.mint),
          onToggleFavorite: () => favs.toggle(
            r.mint,
            name: r.name,
            symbol: r.symbol,
            imageUrl: r.imageUrl,
          ),
          onTap: () => _openPool(
            r.mint,
            favorite: FavoriteToken(
              mint: r.mint,
              name: r.name,
              symbol: r.symbol,
              imageUrl: r.imageUrl,
            ),
          ),
        );
      },
    );
  }

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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: TextField(
              controller: _searchController,
              enabled: !_loading,
              onSubmitted: (v) => _openPool(v),
              decoration: InputDecoration(
                hintText: 'Search by ticker, name or mint...',
                prefixIcon: const Icon(
                  Icons.search,
                  size: 20,
                  color: TibaneColors.textDim,
                ),
                suffixIcon: _loading || _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: TibaneColors.orange,
                          ),
                        ),
                      )
                    : _query.isNotEmpty
                    ? IconButton(
                        onPressed: () => _searchController.clear(),
                        icon: const Icon(Icons.close, size: 18),
                      )
                    : IconButton(
                        onPressed: () => _openPool(_searchController.text),
                        icon: const Icon(Icons.arrow_forward, size: 18),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Expanded(child: _buildBody(favs)),
        ],
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

class _SearchResultTile extends StatelessWidget {
  final TokenSearchResult result;
  final bool isFavorite;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  const _SearchResultTile({
    required this.result,
    required this.isFavorite,
    required this.onTap,
    required this.onToggleFavorite,
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
              child: result.imageUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        result.imageUrl!,
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
                    result.name ?? result.symbol ?? shortenAddress(result.mint),
                    style: const TextStyle(
                      color: TibaneColors.text,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (result.symbol != null)
                    Text(
                      '\$${result.symbol}',
                      style: monoStyle(fontSize: 11, color: TibaneColors.gold),
                    ),
                ],
              ),
            ),
            Text(
              shortenAddress(result.mint),
              style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onToggleFavorite,
              child: Icon(
                isFavorite ? Icons.star : Icons.star_border,
                color: isFavorite ? TibaneColors.gold : TibaneColors.textDim,
                size: 22,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
