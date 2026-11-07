// Helpers for parsing user-entered token amounts.

/// Normalise a user-entered decimal string for parsing: trim surrounding
/// whitespace and convert a comma decimal separator to a dot.
///
/// Many locales' numeric keyboards (most of continental Europe, for example)
/// emit `,` as the decimal key. Dart's number parser and the blockchains /
/// libwallet only understand `.`, so a comma must be normalised before the
/// value is parsed or sent on-chain.
String normalizeDecimal(String text) => text.trim().replaceAll(',', '.');

/// Format base units exactly, without rounding or stripping integer zeroes.
String formatExactTokenAmount(BigInt value, int decimals) {
  final negative = value.isNegative ? '-' : '';
  final digits = value.abs().toString().padLeft(decimals + 1, '0');
  if (decimals == 0) return '$negative$digits';
  final split = digits.length - decimals;
  final fraction = digits.substring(split).replaceFirst(RegExp(r'0+$'), '');
  return '$negative${digits.substring(0, split)}${fraction.isEmpty ? '' : '.$fraction'}';
}

/// Parse a user-entered decimal amount, tolerating a comma decimal separator
/// (see [normalizeDecimal]). Returns null on invalid input — same contract
/// as [double.tryParse].
double? parseAmount(String text) {
  final normalized = normalizeDecimal(text);
  if (normalized.length > 256 ||
      !RegExp(r'^\d*(?:\.\d*)?$').hasMatch(normalized)) {
    return null;
  }
  final value = double.tryParse(normalized);
  return value != null && value.isFinite ? value : null;
}

/// Convert a decimal input to base units without floating-point rounding.
/// Reject nonzero digits beyond the token's precision instead of overspending.
BigInt? parseTokenAmount(String text, int decimals) {
  if (decimals < 0 || decimals > 255 || text.length > 256) return null;
  final match = RegExp(
    r'^(\d*)(?:\.(\d*))?$',
  ).firstMatch(normalizeDecimal(text));
  if (match == null) return null;
  final whole = match[1]!;
  final fraction = match[2] ?? '';
  if (whole.isEmpty && fraction.isEmpty) return null;
  if (fraction.length > decimals &&
      fraction.substring(decimals).contains(RegExp('[1-9]'))) {
    return null;
  }
  final padded = fraction.padRight(decimals, '0').substring(0, decimals);
  final value = BigInt.tryParse('${whole.isEmpty ? '0' : whole}$padded');
  return value != null && value.bitLength <= 256 ? value : null;
}
