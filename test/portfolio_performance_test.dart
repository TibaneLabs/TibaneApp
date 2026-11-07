import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/jupiter_service.dart';
import 'package:tibaneapp/services/portfolio_performance.dart';

void main() {
  test('calculates value-weighted 24-hour portfolio performance', () {
    final result = calculatePortfolioPerformance24h(const [
      PortfolioPosition24h(currentValueUsd: 110, percentChange24h: 10),
      PortfolioPosition24h(currentValueUsd: 190, percentChange24h: -5),
    ]);

    expect(result, isNotNull);
    expect(result!.amountUsd, closeTo(0, 0.000001));
    expect(result.percent, closeTo(0, 0.000001));
  });

  test('does not publish a partial PnL when a valued asset lacks history', () {
    final result = calculatePortfolioPerformance24h(const [
      PortfolioPosition24h(currentValueUsd: 100, percentChange24h: 5),
      PortfolioPosition24h(currentValueUsd: 50, percentChange24h: null),
    ]);

    expect(result, isNull);
  });

  test('calculates a negative dollar amount from a negative price change', () {
    final result = calculatePortfolioPerformance24h(const [
      PortfolioPosition24h(currentValueUsd: 80, percentChange24h: -20),
    ]);

    expect(result!.amountUsd, closeTo(-20, 0.000001));
    expect(result.percent, closeTo(-20, 0.000001));
  });

  test('parses Jupiter current price and 24-hour change', () {
    final quotes = JupiterService.parseTokenPriceQuotes({
      'mint': {'usdPrice': 125.5, 'priceChange24h': -2.75},
    });

    expect(quotes['mint']!.priceUsd, 125.5);
    expect(quotes['mint']!.percentChange24h, -2.75);
  });
}
