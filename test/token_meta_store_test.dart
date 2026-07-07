import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/models/token_account.dart';
import 'package:tibaneapp/services/token_meta_store.dart';

/// A fake batch resolver that records each batch and returns canned metadata.
class _FakeFetch {
  final List<List<String>> batches = [];
  final Map<String, TokenMetadata> data;
  _FakeFetch(this.data);

  Future<Map<String, TokenMetadata>> call(List<String> mints) async {
    batches.add(List.of(mints));
    return {for (final m in mints) if (data[m] != null) m: data[m]!};
  }
}

void main() {
  test('batches concurrent requests into one lookup + caches results', () async {
    final fake = _FakeFetch({
      'mintA': TokenMetadata(mint: 'mintA', symbol: 'A', imageUrl: 'https://a.png'),
      // mintB intentionally absent — Helius has nothing for it.
    });
    final store = TokenMetaStore(fetchBatch: fake.call);

    store.request('mintA');
    store.request('mintB');
    store.request('mintA'); // duplicate — must not add twice

    await Future<void>.delayed(const Duration(milliseconds: 120));

    // One batched call covering both distinct mints.
    expect(fake.batches.length, 1);
    expect(fake.batches.first.toSet(), {'mintA', 'mintB'});

    // Resolved logo cached; the miss is cached as a negative.
    expect(store.logoFor('mintA'), 'https://a.png');
    expect(store.metaFor('mintA')?.symbol, 'A');
    expect(store.logoFor('mintB'), isNull);

    store.dispose();
  });

  test('cached mints (hits and negatives) are never re-requested', () async {
    final fake = _FakeFetch({
      'mintA': TokenMetadata(mint: 'mintA', imageUrl: 'https://a.png'),
    });
    final store = TokenMetaStore(fetchBatch: fake.call);

    store.request('mintA');
    store.request('mintB'); // negative
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(fake.batches.length, 1);

    // Re-requesting either (a hit or a cached miss) triggers no new lookup.
    store.request('mintA');
    store.request('mintB');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(fake.batches.length, 1);

    store.dispose();
  });
}
