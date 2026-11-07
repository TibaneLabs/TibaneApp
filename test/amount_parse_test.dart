import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/utils/amount.dart';

/// Unit tests for the shared amount parser. The bug: locale numeric keyboards
/// emit a comma decimal separator, but Dart's parser and the blockchains only
/// understand a dot, so `parseAmount` / `normalizeDecimal` must convert `,`
/// to `.` (and trim) before the value is parsed or sent on-chain.
void main() {
  test(
    'exact MAX formatting preserves integer zeros and arbitrary precision',
    () {
      expect(formatExactTokenAmount(BigInt.from(20000), 0), '20000');
      expect(formatExactTokenAmount(BigInt.from(20000000000), 6), '20000');
      expect(
        formatExactTokenAmount(BigInt.parse('9007199254740993'), 9),
        '9007199.254740993',
      );
      expect(formatExactTokenAmount(BigInt.zero, 9), '0');
    },
  );
  group('parseTokenAmount', () {
    test('preserves lamports and wei exactly', () {
      expect(parseTokenAmount('0.003024662', 9), BigInt.from(3024662));
      expect(parseTokenAmount('0.000000000000000001', 18), BigInt.one);
      expect(
        parseTokenAmount('99999999999.999999', 6),
        BigInt.parse('99999999999999999'),
      );
    });
    test('accepts comma and leading fractional separators', () {
      expect(parseTokenAmount('0,003024662', 9), BigInt.from(3024662));
      expect(parseTokenAmount(',5', 6), BigInt.from(500000));
      expect(parseTokenAmount('1.', 0), BigInt.one);
    });
    test('rejects negative, malformed and excess nonzero precision', () {
      for (final text in ['', '.', '-1', '1e3', 'NaN', '1.0000001']) {
        expect(parseTokenAmount(text, 6), isNull);
      }
      expect(parseTokenAmount('1.0000000', 6), BigInt.from(1000000));
    });
  });
  group('normalizeDecimal', () {
    test('converts a comma decimal separator to a dot', () {
      expect(normalizeDecimal('1,5'), '1.5');
    });

    test('leaves a dot decimal separator untouched', () {
      expect(normalizeDecimal('1.5'), '1.5');
    });

    test('trims surrounding whitespace', () {
      expect(normalizeDecimal('  2,75  '), '2.75');
    });

    test('handles a leading comma (0,5 style)', () {
      expect(normalizeDecimal(',5'), '.5');
    });
  });

  group('parseAmount', () {
    test('parses a comma decimal as the same value as a dot decimal', () {
      expect(parseAmount('1,5'), 1.5);
      expect(parseAmount('1.5'), 1.5);
    });

    test('parses a plain integer', () {
      expect(parseAmount('42'), 42.0);
    });

    test('trims whitespace before parsing', () {
      expect(parseAmount('  0,25 '), 0.25);
    });

    test('parses a leading-comma fraction', () {
      expect(parseAmount(',5'), 0.5);
    });

    test('returns null for empty / blank input', () {
      expect(parseAmount(''), isNull);
      expect(parseAmount('   '), isNull);
    });

    test('returns null for non-numeric input', () {
      expect(parseAmount('abc'), isNull);
    });

    test('comma input parses to a positive (non-null) value, not a reject', () {
      // Regression: before the fix `double.tryParse('1,5')` returned null,
      // which the send/stake/burn flows treated as "invalid amount".
      final v = parseAmount('1,5');
      expect(v, isNotNull);
      expect(v! > 0, isTrue);
    });
  });
}
