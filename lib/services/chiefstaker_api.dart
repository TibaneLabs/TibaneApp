import 'package:flutter/foundation.dart';

import '../models/staking_pool.dart';
import 'relay_service.dart';

/// Tibane-hosted ChiefStaker directory. One request returns every pool with
/// cached metadata (name, symbol, logo, supply, price, mcap, member count,
/// SOL reward balance), so there's no need to batch Helius calls from the
/// client.
class ChiefStakerApi {
  /// Test/screenshot hook: when set, every `ChiefStakerApi()` returns this
  /// instance instead of constructing a new one. Subclasses constructed
  /// for screenshot mode should call the public [ChiefStakerApi.real] ctor.
  static ChiefStakerApi? testInstance;

  factory ChiefStakerApi() => testInstance ?? ChiefStakerApi.real();

  ChiefStakerApi.real();

  /// List every known pool. Pages through the backend transparently.
  Future<List<StakingPool>> listPools({int perPage = 100}) async {
    final pools = <StakingPool>[];
    var page = 1;
    while (true) {
      final res = await tibaneApi.req(
        'Crypto/Solana/ChiefStaker',
        method: 'GET',
        body: {'results_per_page': perPage, 'page_no': page},
      );
      final rows = (res.data as List?) ?? const [];
      for (final row in rows) {
        if (row is Map) {
          try {
            pools.add(StakingPool.fromApi(Map<String, dynamic>.from(row)));
          } catch (e) {
            debugPrint('ChiefStakerApi: skipped malformed row: $e');
          }
        }
      }
      final paging = res.paging;
      if (paging != null && page < paging.pageMax) {
        page++;
        continue;
      }
      break;
    }
    return pools;
  }

  /// Fetch a single pool by mint. Returns null if unknown.
  Future<StakingPool?> getByMint(String mint) async {
    try {
      final res = await tibaneApi.req(
        'Crypto/Solana/ChiefStaker/$mint',
        method: 'GET',
      );
      final data = res.data;
      if (data is Map) {
        return StakingPool.fromApi(Map<String, dynamic>.from(data));
      }
      return null;
    } catch (e) {
      debugPrint('ChiefStakerApi.getByMint($mint) failed: $e');
      return null;
    }
  }
}
