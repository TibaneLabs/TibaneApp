import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tibaneapp/services/coinbase_spot_price_service.dart';

void main() {
  for (final symbol in ['BTC', 'BCH', 'LTC', 'DOGE']) {
    test('loads $symbol/USD without sending wallet data', () async {
      final service = CoinbaseSpotPriceService(
        symbol: symbol,
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(
            request.url.toString(),
            'https://api.coinbase.com/v2/prices/$symbol-USD/spot',
          );
          expect(request.body, isEmpty);
          return http.Response(
            '{"data":{"amount":"12.5","base":"$symbol","currency":"USD"}}',
            200,
          );
        }),
      );
      addTearDown(service.dispose);

      expect(await service.getPriceUsd(), 12.5);
    });
  }

  test('caches a quote for repeat balance refreshes', () async {
    var calls = 0;
    final service = CoinbaseSpotPriceService(
      symbol: 'BTC',
      client: MockClient((_) async {
        calls++;
        return http.Response(
          '{"data":{"amount":"80000","base":"BTC","currency":"USD"}}',
          200,
        );
      }),
    );
    addTearDown(service.dispose);

    expect(await service.getPriceUsd(), 80000);
    expect(await service.getPriceUsd(), 80000);
    expect(calls, 1);
  });

  test('rejects wrong pair and invalid prices', () async {
    for (final body in [
      '{"data":{"amount":"80000","base":"BCH","currency":"USD"}}',
      '{"data":{"amount":"0","base":"BTC","currency":"USD"}}',
      '{"data":{"amount":"NaN","base":"BTC","currency":"USD"}}',
    ]) {
      final service = CoinbaseSpotPriceService(
        symbol: 'BTC',
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(service.getPriceUsd(), throwsFormatException);
      service.dispose();
    }
  });
}
