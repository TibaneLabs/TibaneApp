import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show NetworkType;
import 'package:tibaneapp/screens/wallet/send_screen.dart';
import 'package:tibaneapp/widgets/tx_success.dart';

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

    test(
      'null when neither a price nor a usable value/balance is available',
      () {
        expect(
          holdingUnitPriceUsd(priceUsd: null, valueUsd: null, uiBalance: 10),
          isNull,
        );
        // Zero balance must not divide-by-zero into NaN/Infinity.
        expect(
          holdingUnitPriceUsd(priceUsd: null, valueUsd: 30, uiBalance: 0),
          isNull,
        );
      },
    );
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

  group('detectSendAddressFamily', () {
    test('classifies Ethereum, Solana, and Bitcoin addresses', () {
      expect(
        detectSendAddressFamily('0x0000000000000000000000000000000000000000'),
        SendAddressFamily.ethereum,
      );
      expect(
        detectSendAddressFamily('So11111111111111111111111111111111111111112'),
        SendAddressFamily.solana,
      );
      expect(
        detectSendAddressFamily('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080'),
        SendAddressFamily.bitcoin,
      );
      expect(
        detectSendAddressFamily('1BoatSLRHtKNngkdXEeobR76b53LETtpyT'),
        SendAddressFamily.bitcoin,
      );
    });

    test('leaves names and malformed addresses unresolved', () {
      expect(detectSendAddressFamily('alice.sol'), isNull);
      expect(detectSendAddressFamily('not an address'), isNull);
    });
  });

  group('sendAddressFamilyForNetworkType', () {
    test('maps libwallet network families to send families', () {
      expect(
        sendAddressFamilyForNetworkType(NetworkType.solana),
        SendAddressFamily.solana,
      );
      expect(
        sendAddressFamilyForNetworkType(NetworkType.evm),
        SendAddressFamily.ethereum,
      );
      expect(
        sendAddressFamilyForNetworkType(NetworkType.bitcoin),
        SendAddressFamily.bitcoin,
      );
    });
  });

  group('explorerNameFor', () {
    test('Solana maps to Solscan', () {
      expect(explorerNameFor(NetworkType.solana, 'mainnet'), 'Solscan');
    });

    test('known EVM chains keep their existing explorers', () {
      expect(explorerNameFor(NetworkType.evm, '1'), 'Etherscan');
      expect(explorerNameFor(NetworkType.evm, '56'), 'BscScan');
      expect(explorerNameFor(NetworkType.evm, '137'), 'Polygonscan');
    });

    test('unknown chain id / type has no branded name', () {
      expect(explorerNameFor(NetworkType.evm, '42161'), isNull);
      expect(explorerNameFor(NetworkType.bitcoin, ''), isNull);
      expect(explorerNameFor(NetworkType.unknown, ''), isNull);
    });
  });
}
