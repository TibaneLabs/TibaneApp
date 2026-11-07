import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tibaneapp/services/eth_usd_price_service.dart';

void main() {
  test('reads a positive ETH/USD spot quote without wallet data', () async {
    final service = EthUsdPriceService(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api.coinbase.com/v2/prices/ETH-USD/spot',
        );
        expect(request.body, isEmpty);
        return http.Response(
          '{"data":{"amount":"2727.85","base":"ETH","currency":"USD"}}',
          200,
        );
      }),
    );
    addTearDown(service.dispose);

    expect(await service.getPriceUsd(), 2727.85);
  });

  test('coalesces requests and caches a recent quote', () async {
    var calls = 0;
    final response = Completer<http.Response>();
    final service = EthUsdPriceService(
      client: MockClient((_) {
        calls++;
        return response.future;
      }),
    );
    addTearDown(service.dispose);

    final first = service.getPriceUsd();
    final second = service.getPriceUsd();
    response.complete(
      http.Response(
        '{"data":{"amount":"2000","base":"ETH","currency":"USD"}}',
        200,
      ),
    );
    expect(await first, 2000);
    expect(await second, 2000);
    expect(await service.getPriceUsd(), 2000);
    expect(calls, 1);
  });

  test('rejects a mismatched pair or nonpositive price', () async {
    for (final body in [
      '{"data":{"amount":"2000","base":"BTC","currency":"USD"}}',
      '{"data":{"amount":"0","base":"ETH","currency":"USD"}}',
      '{"data":{"amount":"bad","base":"ETH","currency":"USD"}}',
    ]) {
      final service = EthUsdPriceService(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(service.getPriceUsd(), throwsFormatException);
      service.dispose();
    }
  });

  test('rejects an HTTP error rather than returning zero', () async {
    final service = EthUsdPriceService(
      client: MockClient((_) async => http.Response('unavailable', 503)),
    );
    addTearDown(service.dispose);

    await expectLater(service.getPriceUsd(), throwsStateError);
  });
}
