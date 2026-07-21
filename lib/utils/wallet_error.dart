import 'package:atonline_api/atonline_api.dart' show AtOnlinePlatformException;
import 'package:libwallet/libwallet.dart' show LibwalletException, SwapError;

/// A user-facing error paired with the original detail for debugging.
///
/// libwallet forwards raw error strings straight from chains, RPC nodes and
/// swap aggregators. Those are unreadable to users ("custom program error:
/// 0xb") but useful to developers. [WalletError] turns any thrown object into
/// a friendly [message] to show the user, while keeping the [raw] text for a
/// copyable "Details" view and for [logError].
///
/// This is the single mapping point — screens should build one with
/// [WalletError.from] instead of interpolating `$e` into a `SnackBar`. See
/// `ERROR_DISPLAY_AUDIT.md`.
///
/// Two libwallet facts drive the design:
///  * The useful discriminator is usually in [LibwalletException.message]
///    (a substring like `insufficient` / `Blockhash not found`), not in
///    [LibwalletException.code] (which is a transport/RPC code). So we match
///    on both.
///  * Swap *quote* failures arrive as data ([SwapError] inside a QuoteAttempt)
///    with a stable [SwapError.code]; swap *execution* failures throw a
///    [LibwalletException]. [from] accepts either.
class WalletError {
  /// Friendly, human-readable message to show the user.
  final String message;

  /// The original error text, preserved for the "Details" affordance and for
  /// [logError]. Never empty.
  final String raw;

  /// Stable code when one is available ([SwapError.code], or a libwallet
  /// transport/RPC code). `null` when the error was matched by message text
  /// only. Intended for tests and future per-code actions (retry, top-up, …).
  final String? code;

  /// When `true` the error should not be surfaced to the user — e.g. they
  /// rejected a web3 request themselves and already know. Callers should skip
  /// display but may still log [raw].
  final bool silent;

  const WalletError({
    required this.message,
    required this.raw,
    this.code,
    this.silent = false,
  });

  /// Map any thrown object to a [WalletError]. Pure and side-effect free so it
  /// is trivially unit-testable; logging happens at the display boundary.
  factory WalletError.from(Object error) {
    if (error is SwapError) return _fromSwapError(error);
    if (error is LibwalletException) return _fromLibwalletException(error);
    if (error is AtOnlinePlatformException) return _fromAtOnline(error);
    if (error is FormatException) {
      final m = error.message.trim();
      return WalletError(
        message: m.isNotEmpty ? m : 'That value is not in a valid format.',
        raw: error.toString(),
      );
    }
    // Plain exceptions: SocketException / TimeoutException / StateError /
    // custom app exceptions whose toString() is already a bare message.
    final raw = error.toString();
    final matched = _matchMessage(raw);
    return WalletError(message: matched ?? _stripPrefixes(raw), raw: raw);
  }

  static WalletError _fromSwapError(SwapError e) {
    final friendly = _swapCodeMessages[e.code] ?? _matchMessage(e.message);
    return WalletError(
      message: friendly ?? _stripPrefixes(e.message),
      raw: e.toString(),
      code: e.code,
    );
  }

  static WalletError _fromLibwalletException(LibwalletException e) {
    // Stable transport/RPC codes we can trust win over message text.
    if (_silentCodes.contains(e.code)) {
      return WalletError(
        message: 'Request cancelled.',
        raw: e.toString(),
        code: e.code,
        silent: true,
      );
    }
    final byCode = _codeMessages[e.code];
    if (byCode != null) {
      return WalletError(message: byCode, raw: _rawOf(e), code: e.code);
    }
    // Otherwise the reason lives in the message (chain/RPC-forwarded or a
    // libwallet-generated string).
    final byMessage = _matchMessage(e.message);
    return WalletError(
      message: byMessage ?? _stripPrefixes(e.message),
      raw: _rawOf(e),
      code: e.code,
    );
  }

  static WalletError _fromAtOnline(AtOnlinePlatformException e) {
    // toString() is unhelpful ("Instance of AtOnlinePlatformException"); the
    // server payload lives in .data.
    final raw = '${e.data}';
    final matched = _matchMessage(raw);
    return WalletError(
      message: matched ?? 'Something went wrong. Please try again.',
      raw: raw,
    );
  }

  /// The raw detail for a [LibwalletException] — prefer the message (which
  /// carries the chain/RPC text), falling back to the full toString().
  static String _rawOf(LibwalletException e) =>
      e.message.trim().isNotEmpty ? e.message : e.toString();

  /// First matching friendly message for [text], or `null`. Case-insensitive.
  static String? _matchMessage(String text) {
    final s = text.toLowerCase();
    for (final rule in _messageRules) {
      if (s.contains(rule.$1)) return rule.$2;
    }
    return null;
  }

  static String _stripPrefixes(String s) =>
      s.replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '').trim();

  @override
  String toString() =>
      'WalletError(code: $code, silent: $silent, message: $message)';
}

// ---------------------------------------------------------------------------
// Rule tables — the single place to add / rename a mapping.
// ---------------------------------------------------------------------------

/// Codes the user triggered themselves — do not surface.
const Set<String> _silentCodes = {'4001'}; // apirouter: user rejected request.

/// Stable libwallet transport / JSON-RPC codes we trust over message text.
/// Deliberately excludes generic codes (400/500) whose real reason lives in
/// the message.
const Map<String, String> _codeMessages = {
  '4902': "This network isn't supported yet.",
  '-32602': 'Network configuration problem. Check the RPC settings.',
  '503': 'The wallet is busy. Please try again.',
};

/// Stable [SwapError.code] values (see swap_quote.dart). Safe to branch on.
const Map<String, String> _swapCodeMessages = {
  'no_liquidity': 'No swap route for this pair right now.',
  'unsupported_token_pair': 'No swap route for this pair right now.',
  'unsupported_chain': "Swaps aren't supported on this network.",
  'slippage_exceeded': 'The price moved. Try again or raise the slippage.',
  'quote_expired': 'That quote expired. Fetching a fresh one.',
  'quote_not_found': 'That quote expired. Fetching a fresh one.',
  'provider_unavailable': 'The swap service is unavailable. Please try again.',
  'provider_bad_request':
      'That swap was rejected. Try a different amount or token.',
  'invalid_request': "That swap request wasn't valid.",
  'missing_api_key': 'Swaps are temporarily unavailable.',
};

/// Ordered message-substring rules (lower-cased needle → friendly message).
/// Order matters: put specific patterns before general ones. Device-transfer
/// tokens are intentionally left to [LibwalletBackend.friendlyTransferError],
/// which has richer transfer-specific copy and disambiguates 'timeout' /
/// 'declined'.
const List<(String, String)> _messageRules = [
  // Auth / unlock (libwallet-generated).
  ('wrong password', 'Incorrect password.'),
  (
    'wrong storekey',
    'Could not unlock this wallet. Try restoring it from cloud backup.',
  ),
  // Chain-forwarded, deterministic.
  ('blockhash not found', 'The network was busy. Please try again.'),
  ('block height exceeded', 'The network was busy. Please try again.'),
  ('exceeds desired slippage', 'The price moved too much. Please try again.'),
  ('slippage', 'The price moved too much. Please try again.'),
  // Rent exemption: sending would drop the account below the minimum SOL it
  // must keep to stay open. libwallet points at Transaction:maxSendable, which
  // the send screen exposes as the MAX button.
  (
    'rent-exempt',
    'Sending this much would leave too little SOL to keep your account open. '
        'Send a little less, or tap MAX to send the most you safely can.',
  ),
  ('insufficient', "You don't have enough balance to cover this transaction."),
  ('custom program error', 'The transaction was rejected on-chain.'),
  ('error processing instruction', 'The transaction was rejected on-chain.'),
  // Swap routing (aggregator strings).
  ('failed to get quotes', 'No swap route available right now.'),
  ('no route', 'No swap route available right now.'),
  // RPC configuration (libwallet-generated).
  ('rpc url', 'Invalid RPC URL.'),
  // Network / client-side.
  ('socketexception', 'No internet connection.'),
  ('failed host lookup', 'No internet connection.'),
  ('no address associated', 'No internet connection.'),
  ('connection refused', 'Server unavailable. Please try again later.'),
  ('connection reset', 'Server unavailable. Please try again later.'),
  ('timeoutexception', 'The request timed out. Please try again.'),
  ('timed out', 'The request timed out. Please try again.'),
];
