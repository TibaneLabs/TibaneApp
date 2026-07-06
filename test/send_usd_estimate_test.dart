import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/screens/wallet/send_screen.dart';

/// Unit tests for the send-screen "≈ $X" amount estimate helpers.
void main() {
  group('holdingUnitPriceUsd', () {
    test('uses the direct per-unit price when present', () {
      expect(
        holdingUnitPriceUsd(priceUsd: 1.5, valueUsd: 30, uiBalance: 10),
        1.5,
      );
    });

    test('falls back to value ÷ balance when no unit price', () {
      expect(
        holdingUnitPriceUsd(priceUsd: null, valueUsd: 30, uiBalance: 10),
        3.0,
      );
    });

    test('null when neither a price nor a usable value/balance is available', () {
      expect(
        holdingUnitPriceUsd(priceUsd: null, valueUsd: null, uiBalance: 10),
        isNull,
      );
      // Zero balance must not divide-by-zero into NaN/Infinity.
      expect(
        holdingUnitPriceUsd(priceUsd: null, valueUsd: 30, uiBalance: 0),
        isNull,
      );
    });
  });

  group('formatSendUsd', () {
    test('two decimals for ordinary amounts', () {
      expect(formatSendUsd(12.5), '\$12.50');
      expect(formatSendUsd(0.01), '\$0.01');
    });

    test('dust shows the sub-cent floor', () {
      expect(formatSendUsd(0.004), '< \$0.01');
    });

    test('K / M / B suffixes for large amounts', () {
      expect(formatSendUsd(1500), '\$1.50K');
      expect(formatSendUsd(2.5e6), '\$2.50M');
      expect(formatSendUsd(3e9), '\$3.00B');
    });

    test('zero renders as plain two-decimal, not the dust floor', () {
      expect(formatSendUsd(0), '\$0.00');
    });
  });
}
