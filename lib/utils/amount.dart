// Helpers for parsing user-entered token amounts.

/// Normalise a user-entered decimal string for parsing: trim surrounding
/// whitespace and convert a comma decimal separator to a dot.
///
/// Many locales' numeric keyboards (most of continental Europe, for example)
/// emit `,` as the decimal key. Dart's number parser and the blockchains /
/// libwallet only understand `.`, so a comma must be normalised before the
/// value is parsed or sent on-chain.
String normalizeDecimal(String text) => text.trim().replaceAll(',', '.');

/// Parse a user-entered decimal amount, tolerating a comma decimal separator
/// (see [normalizeDecimal]). Returns null on invalid input — same contract
/// as [double.tryParse].
double? parseAmount(String text) => double.tryParse(normalizeDecimal(text));
