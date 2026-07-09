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

  group('formatSendAmountGrouped', () {
    test('groups thousands and strips trailing zeros', () {
      expect(formatSendAmountGrouped(10000, 6), '10,000');
      expect(formatSendAmountGrouped(1234567, 2), '1,234,567');
    });

    test('keeps significant fractional digits, groups the integer part', () {
      expect(formatSendAmountGrouped(1234.5, 9), '1,234.5');
      expect(formatSendAmountGrouped(0.5, 9), '0.5');
    });

    test('sub-thousand values are ungrouped', () {
      expect(formatSendAmountGrouped(999, 0), '999');
      expect(formatSendAmountGrouped(0, 6), '0');
    });

    test('boundary at exactly one thousand gets a separator', () {
      expect(formatSendAmountGrouped(1000, 2), '1,000');
    });
  });
}
