import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../services/favorites_service.dart';
import '../services/wallet/libwallet_backend.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import 'tibane_card.dart';
import 'token_icon.dart';

/// Reusable token-search surface: a debounced search field over
/// libwallet's curated token registry, with results rendered as
/// tappable tiles and (optionally) a per-row favourite toggle.
///
/// The widget owns no opinions about layout above or below itself —
/// the caller supplies the [emptyBody] (usually a favourites list or
/// a "popular tokens" panel) shown when the field is empty.
///
/// Typical layout:
///
/// ```dart
/// Column(children: [
///   header,
///   const SizedBox(height: 16),
///   Expanded(child: TokenSearch(
///     onResultSelected: (r) => navigateToPool(r.mint),
///     emptyBody: favouritesList,
///   )),
/// ])
/// ```
///
/// State transitions: empty query → [emptyBody]. Mint-shaped query
/// (32–44 chars) → "Press enter" hint; [onMintSubmitted] fires on
/// submit/arrow press if provided, otherwise the mint is fed to the
/// curated search like any other query. Non-mint query → debounced
/// 350ms search via [LibwalletBackend.searchCuratedTokens]; results
/// or a "no matches" message. Stale-response races are dropped via a
/// monotonic sequence counter.
class TokenSearch extends StatefulWidget {
  /// Triggered when the user taps a search result.
  final void Function(TokenSearchResult result) onResultSelected;

  /// Triggered when the user submits / hits the arrow on a
  /// mint-shaped query. When null, mint-shaped input falls through
  /// to the curated search like any other query.
  ///
  /// The widget shows the suffix-icon spinner while the returned
  /// future is in flight, so handlers can do async work
  /// (e.g. on-chain metadata lookup) without their own UI plumbing.
  final Future<void> Function(String mint)? onMintSubmitted;

  /// Hint shown in the empty search field.
  final String hintText;

  /// Body to render when the search query is empty. Typically a list
  /// of favourites or popular tokens.
  final Widget emptyBody;

  /// Whether to render a star toggle on the trailing edge of each
  /// search result tile. Tapping it flips the [FavoritesService]
  /// state for the result's mint.
  final bool showFavoriteToggle;

  /// Horizontal padding applied to the search field row and the
  /// results list. Matches the host screen's own padding so the
  /// widget visually slots in without an extra inset.
  final EdgeInsetsGeometry padding;

  /// Optional scroll controller to bind to the results list. Hosts
  /// embedded in a [DraggableScrollableSheet] should pass the
  /// builder's controller so the drag-to-collapse handoff works
  /// when results are visible. If null, the results list uses a
  /// fresh controller.
  final ScrollController? scrollController;

  const TokenSearch({
    super.key,
    required this.onResultSelected,
    required this.emptyBody,
    this.onMintSubmitted,
    this.hintText = 'Search by ticker, name or mint...',
    this.showFavoriteToggle = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.scrollController,
  });

  @override
  State<TokenSearch> createState() => _TokenSearchState();
}

class _TokenSearchState extends State<TokenSearch> {
  final _controller = TextEditingController();
  String _query = '';
  Timer? _debounce;
  bool _searching = false;
  List<TokenSearchResult> _results = const [];
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  bool _isMintShaped(String s) => s.length >= 32 && s.length <= 44;

  void _onChanged() {
    final value = _controller.text.trim();
    if (value == _query) return;
    // Invalidate any in-flight search or mint resolution so its
    // stale result can't land in _results after the user has moved
    // on (cleared the field, retyped, pasted a different value).
    _searchSeq++;
    _debounce?.cancel();
    final willDebounceSearch = value.isNotEmpty &&
        !(_isMintShaped(value) && widget.onMintSubmitted != null);
    setState(() {
      _query = value;
      // Drop any prior results immediately — keeping them around
      // while the next search runs flashes wrong data.
      _results = const [];
      // Treat the debounce window as part of the loading state so we
      // don't flash "No tokens match …" between keystrokes.
      _searching = willDebounceSearch;
    });
    if (!willDebounceSearch) return;
    _debounce =
        Timer(const Duration(milliseconds: 350), () => _runSearch(value));
  }

  Future<void> _runSearch(String query) async {
    final mySeq = ++_searchSeq;
    if (!mounted) return;
    setState(() => _searching = true);
    final wallet = context.read<WalletService>();
    final results = await wallet.libwallet.searchCuratedTokens(query);
    if (!mounted || mySeq != _searchSeq) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  Future<void> _onSubmit(String value) async {
    // Drop repeat Enter presses (keyboard or arrow) while a previous
    // mint resolution or curated search is still in flight. Without
    // this guard a hardware-Enter double-tap would call the handler
    // twice and potentially push two screens / fire two metadata
    // fetches.
    if (_searching) return;
    final trimmed = value.trim();
    final handler = widget.onMintSubmitted;
    if (handler == null || !_isMintShaped(trimmed)) return;
    // Bump the seq so any in-flight curated search can't overwrite
    // _searching while the mint resolves.
    final mySeq = ++_searchSeq;
    setState(() => _searching = true);
    try {
      await handler(trimmed);
    } finally {
      if (mounted && mySeq == _searchSeq) {
        setState(() => _searching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: widget.padding,
          child: TextField(
            controller: _controller,
            onSubmitted: _onSubmit,
            decoration: InputDecoration(
              hintText: widget.hintText,
              prefixIcon: const Icon(
                Icons.search,
                size: 20,
                color: TibaneColors.textDim,
              ),
              suffixIcon: _searching
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
                      ? (widget.onMintSubmitted != null &&
                              _isMintShaped(_query)
                          ? IconButton(
                              onPressed: () => _onSubmit(_controller.text),
                              icon: const Icon(Icons.arrow_forward, size: 18),
                            )
                          : IconButton(
                              onPressed: () => _controller.clear(),
                              icon: const Icon(Icons.close, size: 18),
                            ))
                      : null,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_query.isEmpty) return widget.emptyBody;
    if (_isMintShaped(_query) && widget.onMintSubmitted != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Press Enter to use this mint.',
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
    final favs = context.watch<FavoritesService>();
    return ListView.builder(
      controller: widget.scrollController,
      padding: widget.padding,
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final r = _results[index];
        return _SearchResultTile(
          result: r,
          isFavorite: widget.showFavoriteToggle && favs.isFavorite(r.mint),
          showFavoriteToggle: widget.showFavoriteToggle,
          onTap: () => widget.onResultSelected(r),
          onToggleFavorite: widget.showFavoriteToggle
              ? () => favs.toggle(
                    r.mint,
                    name: r.name,
                    symbol: r.symbol,
                    imageUrl: r.imageUrl,
                  )
              : null,
        );
      },
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  final TokenSearchResult result;
  final bool isFavorite;
  final bool showFavoriteToggle;
  final VoidCallback onTap;
  final VoidCallback? onToggleFavorite;

  const _SearchResultTile({
    required this.result,
    required this.isFavorite,
    required this.showFavoriteToggle,
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
            TokenIcon(
              imageUrl: result.imageUrl,
              mint: result.mint,
              symbol: result.symbol ?? '?',
              size: 36,
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
            if (showFavoriteToggle && onToggleFavorite != null) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onToggleFavorite,
                child: Icon(
                  isFavorite ? Icons.star : Icons.star_border,
                  color:
                      isFavorite ? TibaneColors.gold : TibaneColors.textDim,
                  size: 22,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
