import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/services/token_icon_cache.dart';
import 'package:tibaneapp/widgets/token_icon.dart';

void main() {
  const logo = 'https://example.com/token.png';
  late Directory dir;
  late DateTime now;
  late List<Uri> requests;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('token-icons-test-');
    now = DateTime.utc(2026, 11, 11);
    requests = [];
  });
  tearDown(() => dir.delete(recursive: true));

  TokenIconCache cache({int maxBytes = 1024}) => TokenIconCache(
    directory: () async => dir,
    now: () => now,
    maxBytes: maxBytes,
    fetchThumbnail: (uri) async {
      requests.add(uri);
      return Uint8List.fromList([1, 2, 3]);
    },
  );

  test(
    'recovers a thumbnail by mint after reopening, without its URL',
    () async {
      final first = cache();
      await first.recordSolanaHoldings('account-a', [usdcMint]);
      expect(await first.load(mint: usdcMint, urls: [logo]), [1, 2, 3]);
      final reopened = cache();
      expect(await reopened.load(mint: usdcMint), [1, 2, 3]);
      expect(requests, [Uri.parse(logo)]);
    },
  );

  testWidgets('TokenIcon displays the saved image with no source URL', (
    tester,
  ) async {
      const mint = '2cHr7QS3xfuSV8wdxo3ztuF4xbiarF6Nrgx3qpx3HzXR';
    await tester.runAsync(() async {
      final fixture = await rootBundle.load('assets/icons/sol.png');
      final first = TokenIconCache(
        directory: () async => dir,
        now: () => now,
        fetchThumbnail: (_) async => fixture.buffer.asUint8List(),
      );
      await first.load(mint: mint, urls: [logo]);
        final reopened = cache(maxBytes: 128 * 1024);
      await tester.pumpWidget(
        Provider<TokenIconCache>.value(
          value: reopened,
          child: const MaterialApp(
            home: TokenIcon(mint: mint, symbol: 'TEST'),
          ),
        ),
      );
      // Wait for the widget's serialized disk read to complete.
        expect(await reopened.load(mint: mint), isNotEmpty);
    });
    await tester.pumpAndSettle();
    expect(tester.widget<Image>(find.byType(Image)).image, isA<MemoryImage>());
    expect(requests, isEmpty);
  });

  test(
    'expires three days after the last known account stops holding',
    () async {
      final first = cache();
      await first.recordSolanaHoldings('account-a', [usdcMint]);
      await first.recordSolanaHoldings('account-b', [usdcMint]);
      await first.load(mint: usdcMint, urls: [logo]);
      await first.recordSolanaHoldings('account-a', []);

      now = now.add(const Duration(days: 4));
      final reopened = cache();
      expect(await reopened.load(mint: usdcMint), [1, 2, 3]);
      await reopened.recordSolanaHoldings('account-b', []);

      now = now.add(const Duration(days: 2, hours: 23));
      expect(await reopened.load(mint: usdcMint), [1, 2, 3]);
      now = now.add(const Duration(hours: 1));
      expect(await cache().load(mint: usdcMint), isNull);
      expect(
        await dir.list().where((file) => file.path.endsWith('.png')).length,
        0,
      );
    },
  );

  test('evicts a recently viewed unowned icon before a held one', () async {
    final store = cache(maxBytes: 6);
    await store.recordSolanaHoldings('account', [usdcMint]);
    await store.load(mint: usdcMint, urls: [logo]);
    now = now.add(const Duration(hours: 1));
    await store.load(mint: usdtMint, urls: [logo]);
    now = now.add(const Duration(hours: 1));
    await store.load(mint: chiefPussyMint, urls: [logo]);
    expect(await store.load(mint: usdtMint), isNull);
    expect(await store.load(mint: usdcMint), [1, 2, 3]);
    expect(await store.load(mint: chiefPussyMint), [1, 2, 3]);
    final files = await dir
        .list()
        .where((f) => f.path.endsWith('.png'))
        .toList();
    expect(files, hasLength(2));
  });

  test(
    'retries an alternate gateway and shares concurrent downloads',
    () async {
      final gate = Completer<void>();
      final store = TokenIconCache(
        directory: () async => dir,
        now: () => now,
        fetchThumbnail: (uri) async {
          requests.add(uri);
          if (uri.host == 'example.com') return null;
          await gate.future;
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      const alternate = 'https://example.org/token.png';
      final a = store.load(mint: usdcMint, urls: [logo, alternate]);
      final b = store.load(mint: usdcMint, urls: [logo, alternate]);
      gate.complete();
      expect(await Future.wait([a, b]), [
        [1, 2, 3],
        [1, 2, 3],
      ]);
      expect(requests, [Uri.parse(logo), Uri.parse(alternate)]);
    },
  );
}
