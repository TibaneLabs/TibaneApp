import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../services/token_meta_store.dart';
import '../theme/tibane_theme.dart';

/// Round token logo with a colored initial as fallback.
///
/// Render priority:
/// 1. [assetPath] — a bundled Flutter asset (`assets/...`). Used for every
///    network's native token so they never depend on a metadata server.
/// 2. If [mint] has a bundled logo ([kBundledTokenIcons] — SOL, USDC, USDT,
///    ChiefPussy), that asset is used (offline + crisp; metadata servers are
///    unreliable for these, e.g. USDT has no logo).
/// 3. [imageUrl] — fetched via [Image.network].
/// 4. If no [imageUrl] but [mint] is a Solana-shaped mint, the logo is resolved
///    from the shared [TokenMetaStore] (Helius backfill), so tokens whose source
///    list carries no logo still get their icon — consistent across every
///    surface. See TOKEN_METADATA_REGISTRY.md.
/// 5. Coloured initial placeholder.
class TokenIcon extends StatelessWidget {
  final String? imageUrl;
  final String? assetPath;
  final String? mint;
  final String symbol;
  final double size;

  const TokenIcon({
    super.key,
    this.imageUrl,
    this.assetPath,
    this.mint,
    required this.symbol,
    this.size = 32,
  });

  static bool _isSolanaShaped(String m) =>
      !m.startsWith('0x') && m.length >= 32 && m.length <= 44;

  @override
  Widget build(BuildContext context) {
    if (assetPath != null && assetPath!.isNotEmpty) {
      return _assetImage(assetPath!, size, symbol);
    }
    final m = mint;
    final bundled = m == null ? null : kBundledTokenIcons[m];
    if (bundled != null) return _assetImage(bundled, size, symbol);
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return _networkImage(imageUrl!, size, symbol);
    }
    // No direct logo — resolve via the shared token-metadata store, falling
    // back to the coloured initial until (or unless) one lands.
    if (m != null && _isSolanaShaped(m)) {
      return _ResolvingIcon(mint: m, symbol: symbol, size: size);
    }
    return tokenIconFallback(symbol, size);
  }
}

Widget _assetImage(String path, double size, String symbol) => ClipRRect(
  borderRadius: BorderRadius.circular(size / 2),
  child: Image.asset(
    path,
    width: size,
    height: size,
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => tokenIconFallback(symbol, size),
  ),
);

Widget _networkImage(String url, double size, String symbol) =>
    _ResilientNetworkImage(url: url, size: size, symbol: symbol);

/// Returns the original image URL followed by a public IPFS fallback when the
/// metadata points at IPFS. Some gateways rate-limit mobile clients even when
/// the underlying image is healthy.
@visibleForTesting
List<String> tokenImageCandidates(String url) {
  final candidates = <String>[url];
  String? ipfsPath;

  if (url.startsWith('ipfs://')) {
    ipfsPath = url
        .substring('ipfs://'.length)
        .replaceFirst(RegExp(r'^ipfs/'), '');
  } else {
    final marker = url.indexOf('/ipfs/');
    if (marker >= 0) ipfsPath = url.substring(marker + '/ipfs/'.length);
  }

  if (ipfsPath != null && ipfsPath.isNotEmpty) {
    final fallback = 'https://gateway.pinata.cloud/ipfs/$ipfsPath';
    if (!candidates.contains(fallback)) candidates.add(fallback);
  }
  return candidates;
}

class _ResilientNetworkImage extends StatefulWidget {
  final String url;
  final double size;
  final String symbol;

  const _ResilientNetworkImage({
    required this.url,
    required this.size,
    required this.symbol,
  });

  @override
  State<_ResilientNetworkImage> createState() => _ResilientNetworkImageState();
}

class _ResilientNetworkImageState extends State<_ResilientNetworkImage> {
  late List<String> _candidates;
  int _index = 0;
  bool _advanceQueued = false;

  @override
  void initState() {
    super.initState();
    _candidates = tokenImageCandidates(widget.url);
  }

  @override
  void didUpdateWidget(covariant _ResilientNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _candidates = tokenImageCandidates(widget.url);
      _index = 0;
    }
  }

  void _tryNextCandidate() {
    if (_advanceQueued || _index >= _candidates.length - 1) return;
    _advanceQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _advanceQueued = false;
      if (!mounted || _index >= _candidates.length - 1) return;
      setState(() => _index++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final fallback = tokenIconFallback(widget.symbol, widget.size);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.size / 2),
      child: Image.network(
        _candidates[_index],
        key: ValueKey(_candidates[_index]),
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
        errorBuilder: (_, _, _) {
          _tryNextCandidate();
          return fallback;
        },
      ),
    );
  }
}

/// Coloured-initial placeholder shown when no logo is available.
Widget tokenIconFallback(String symbol, double size) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(
    color: TibaneColors.orange.withValues(alpha: 0.15),
    shape: BoxShape.circle,
  ),
  child: Center(
    child: Text(
      symbol.isNotEmpty ? symbol[0].toUpperCase() : '?',
      style: TextStyle(
        color: TibaneColors.orange,
        fontWeight: FontWeight.w700,
        fontSize: size * 0.45,
      ),
    ),
  ),
);

/// Renders a token whose logo isn't known yet: asks [TokenMetaStore] to resolve
/// the mint (batched Helius lookup) and shows the logo once it lands, else the
/// coloured initial. Degrades to the fallback when the store isn't in the tree.
class _ResolvingIcon extends StatefulWidget {
  final String mint;
  final String symbol;
  final double size;

  const _ResolvingIcon({
    required this.mint,
    required this.symbol,
    required this.size,
  });

  @override
  State<_ResolvingIcon> createState() => _ResolvingIconState();
}

class _ResolvingIconState extends State<_ResolvingIcon> {
  @override
  void initState() {
    super.initState();
    // Request after the first frame so we never mutate provider state mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        context.read<TokenMetaStore>().request(widget.mint);
      } catch (_) {
        // Store not provided (e.g. an isolated widget test) — keep the fallback.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    String? url;
    try {
      url = context.select<TokenMetaStore, String?>(
        (s) => s.logoFor(widget.mint),
      );
    } catch (_) {
      return tokenIconFallback(widget.symbol, widget.size);
    }
    if (url != null && url.isNotEmpty) {
      return _networkImage(url, widget.size, widget.symbol);
    }
    return tokenIconFallback(widget.symbol, widget.size);
  }
}
