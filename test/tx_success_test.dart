import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show NetworkType;
import 'package:tibaneapp/widgets/tx_success.dart';

/// Unit tests for the shared transaction confirm / success helpers.
void main() {
  group('formatAmountGrouped', () {
    test('groups the integer part and strips trailing zeros', () {
      expect(formatAmountGrouped(10000), '10,000');
      expect(formatAmountGrouped(1234567.5), '1,234,567.5');
      expect(formatAmountGrouped(1000), '1,000');
    });

    test('keeps sub-one precision and small values ungrouped', () {
      expect(formatAmountGrouped(0.82), '0.82');
      expect(formatAmountGrouped(0), '0');
      expect(formatAmountGrouped(999), '999');
    });

    test('honours the maxDecimals cap', () {
      expect(formatAmountGrouped(0.123456789, maxDecimals: 4), '0.1235');
      expect(formatAmountGrouped(2.5, maxDecimals: 0), '3'); // rounds
    });
  });

  group('shortenTxHash', () {
    test('null stays null; short strings are unchanged', () {
      expect(shortenTxHash(null), isNull);
      expect(shortenTxHash('1234567890123456'), '1234567890123456'); // 16
    });

    test('long signatures get a middle ellipsis', () {
      final s = shortenTxHash('1234567890abcdefghij'); // 20 chars
      expect(s, '12345678…efghij');
    });
  });

  group('explorerNameFor', () {
    test('uses Solscan for Solana and the existing EVM explorers', () {
      expect(explorerNameFor(NetworkType.solana, 'mainnet'), 'Solscan');
      expect(explorerNameFor(NetworkType.evm, '1'), 'Etherscan');
      expect(explorerNameFor(NetworkType.evm, '56'), 'BscScan');
      expect(explorerNameFor(NetworkType.evm, '137'), 'Polygonscan');
      expect(explorerNameFor(NetworkType.evm, '8453'), isNull);
      expect(explorerNameFor(NetworkType.bitcoin, ''), isNull);
    });
  });

  group('Solscan URL helpers', () {
    test('builds Solscan transaction, account and token URLs', () {
      expect(solscanTxUrl('abc'), 'https://solscan.io/tx/abc');
      expect(solscanAccountUrl('holder'), 'https://solscan.io/account/holder');
      expect(solscanTokenUrl('mint'), 'https://solscan.io/token/mint');
      expect(
        solscanTokenUrl('mint', holders: true),
        'https://solscan.io/token/mint#holders',
      );
    });
  });
}
