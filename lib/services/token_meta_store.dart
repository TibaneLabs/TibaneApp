import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/token_account.dart' show TokenMetadata;
import 'rpc_service.dart';

/// Batch metadata resolver (mints -> mint→meta). Defaults to Helius via
/// [RpcService.getAssetBatch]; injectable so tests can supply a fake.
typedef TokenMetaFetch =
    Future<Map<String, TokenMetadata>> Function(List<String> mints);

/// Single source of truth for token *display* metadata (logo / symbol / name),
/// keyed by mint. Surfaces that don't already carry a logo — swap search /
/// popular, libwallet-sourced rows, etc. — resolve it here instead of each
/// having its own metadata source, so icons are consistent everywhere. See
/// TOKEN_METADATA_REGISTRY.md.
///
/// Backed by Helius DAS `getAssetBatch`, which covers far more SPL tokens than
/// libwallet's token list. Lookups are **batched** (a burst of icons rendering
/// at once collapses into one RPC call, ~60ms debounce) and cached for the
/// session. Consumed by [TokenIcon], which resolves any missing logo through
/// this store.
class TokenMetaStore extends ChangeNotifier {
  TokenMetaStore({TokenMetaFetch? fetchBatch})
    : _rpc = fetchBatch == null ? RpcService() : null,
      _fetch = fetchBatch;

  // Own an RpcService only when using the default resolver; null when a
  // fetchBatch was injected (tests).
  final RpcService? _rpc;
  final TokenMetaFetch? _fetch;

  // mint -> meta. A present key with a null value means "resolved, Helius had
  // nothing" — so we don't keep re-requesting it. Absent key = never requested.
  final Map<String, TokenMetadata?> _cache = {};
  final Set<String> _pending = {};
  Timer? _flushTimer;
  bool _disposed = false;

  static const _flushDelay = Duration(milliseconds: 60);
  static const _batchCap = 100; // getAssetBatch supports up to 1000; stay modest

  /// Cached metadata for [mint], or null if unresolved / not found.
  TokenMetadata? metaFor(String mint) => _cache[mint];

  /// Resolved non-empty logo URL for [mint], or null.
  String? logoFor(String mint) {
    final url = _cache[mint]?.imageUrl;
    return (url != null && url.isNotEmpty) ? url : null;
  }

  /// Request metadata for [mint]. No-op if already cached or in flight; else
  /// schedules a batched Helius lookup. Safe to call during build — all
  /// notification is deferred to the batch flush.
  void request(String mint) {
    if (mint.isEmpty || _cache.containsKey(mint) || _pending.contains(mint)) {
      return;
    }
    _pending.add(mint);
    _flushTimer ??= Timer(_flushDelay, _flush);
  }

  Future<void> _flush() async {
    _flushTimer = null;
    if (_pending.isEmpty) return;
    final batch = _pending.take(_batchCap).toList();
    _pending.removeAll(batch);
    try {
      final metas = await (_fetch ?? _rpc!.getAssetBatch)(batch);
      if (_disposed) return;
      for (final mint in batch) {
        _cache[mint] = metas[mint]; // null when Helius returned nothing
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[tokenmeta] getAssetBatch failed: $e');
      // Leave these mints uncached so a later request retries.
    }
    // Anything requested while we were fetching gets its own flush.
    if (!_disposed && _pending.isNotEmpty) {
      _flushTimer ??= Timer(_flushDelay, _flush);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _rpc?.dispose();
    super.dispose();
  }
}
