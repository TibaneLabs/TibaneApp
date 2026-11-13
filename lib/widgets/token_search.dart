import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../l10n/l10n.dart';
import '../services/wallet/libwallet_backend.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import 'token_picker_tile.dart';

/// Reusable token-search surface: a debounced search field over
/// libwallet's curated token registry, with results rendered as tappable tiles.
///
/// The widget owns no opinions about layout above or below itself —
/// the caller can supply an [emptyBody] shown when the field is empty.
///
/// Typical layout:
///
/// ```dart
/// Column(children: [
///   header,
///   const SizedBox(height: 16),
///   Expanded(child: TokenSearch(
///     onResultSelected: (r) => navigateToPool(r.mint),
///     emptyBody: popularTokens,
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

  /// Hint shown in the empty search field. When null the localized default
  /// [AppLocalizations.tokenSearchHint] is used at build time.
  final String? hintText;

  /// Body to render when the search query is empty.
  final Widget emptyBody;

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
    this.emptyBody = const SizedBox.shrink(),
    this.onMintSubmitted,
    this.hintText,
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
    final willDebounceSearch =
        value.isNotEmpty &&
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
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _runSearch(value),
    );
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
    final l10n = context.l10n;
    return Column(
      children: [
        Padding(
          padding: widget.padding,
          child: TextField(
            controller: _controller,
            onSubmitted: _onSubmit,
            decoration: InputDecoration(
              hintText: widget.hintText ?? l10n.tokenSearchHint,
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
                  ? (widget.onMintSubmitted != null && _isMintShaped(_query)
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
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = context.l10n;
    if (_query.isEmpty) return widget.emptyBody;
    if (_isMintShaped(_query) && widget.onMintSubmitted != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.tokenSearchPressEnter,
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
            l10n.tokenSearchNoResults(_query),
            textAlign: TextAlign.center,
            style: TextStyle(color: TibaneColors.textMuted),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: widget.scrollController,
      padding: widget.padding,
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final r = _results[index];
        final address = shortenAddress(r.mint);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TokenPickerTile(
            mint: r.mint,
            name: r.name ?? r.symbol ?? address,
            symbol: r.symbol,
            imageUrl: r.imageUrl,
            framed: true,
            trailing: Text(
              address,
              style: monoStyle(fontSize: 15, color: TibaneColors.orange),
            ),
            onTap: () => widget.onResultSelected(r),
          ),
        );
      },
    );
  }
}
