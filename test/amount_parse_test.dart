import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/utils/amount.dart';

/// Unit tests for the shared amount parser. The bug: locale numeric keyboards
/// emit a comma decimal separator, but Dart's parser and the blockchains only
/// understand a dot, so `parseAmount` / `normalizeDecimal` must convert `,`
/// to `.` (and trim) before the value is parsed or sent on-chain.
void main() {
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
