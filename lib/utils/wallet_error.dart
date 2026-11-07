import 'package:atonline_api/atonline_api.dart' show AtOnlinePlatformException;
import 'package:flutter/widgets.dart';
import 'package:libwallet/libwallet.dart' show LibwalletException, SwapError;

import '../l10n/gen/app_localizations.dart';

enum WalletErrorKey {
  mnemonicRollbackIncomplete,
  backupRollbackIncomplete,
  operationChanged,
  partialBroadcast,
  passwordUpdateIncomplete,
  requestCancelled,
  unsupportedNetwork,
  networkConfiguration,
  walletBusy,
  incorrectPassword,
  privateKeyWalletBackup,
  walletUnlockCloudBackup,
  networkBusy,
  priceMoved,
  priceMovedRaiseSlippage,
  rentExemptMinimum,
  insufficientBalance,
  transactionRejected,
  noSwapRoute,
  swapQuoteUnavailable,
  swapQuoteExpired,
  invalidValue,
  signingUnavailable,
  importedSolanaPromotionUnavailable,
  mnemonicMpcUnavailable,
  promotionIdentityChanged,
  swapsUnsupportedNetwork,
  swapServiceUnavailable,
  swapRejected,
  invalidSwapRequest,
  swapsTemporarilyUnavailable,
  invalidRpcUrl,
  noInternet,
  serverUnavailable,
  requestTimedOut,
  genericRetry,
}

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

  /// Stable localization key. Unrecognized errors use a generic localized
  /// message; their original text is available only through [raw].
  final WalletErrorKey? key;

  /// When `true` the error should not be surfaced to the user — e.g. they
  /// rejected a web3 request themselves and already know. Callers should skip
  /// display but may still log [raw].
  final bool silent;

  const WalletError({
    required this.message,
    required this.raw,
    this.code,
    this.key,
    this.silent = false,
  });

  String localizedMessage(AppLocalizations l10n) {
    switch (key) {
      case WalletErrorKey.mnemonicRollbackIncomplete:
        return l10n.seedCreateIncomplete;
      case WalletErrorKey.backupRollbackIncomplete:
        return l10n.walletBackupRestoreIncomplete;
      case WalletErrorKey.operationChanged:
        return l10n.walletOperationChanged;
      case WalletErrorKey.partialBroadcast:
        return l10n.walletPartialBroadcast;
      case WalletErrorKey.passwordUpdateIncomplete:
        return l10n.walletPasswordUpdateIncomplete;
      case WalletErrorKey.requestCancelled:
        return l10n.walletErrorRequestCancelled;
      case WalletErrorKey.unsupportedNetwork:
        return l10n.walletErrorUnsupportedNetwork;
      case WalletErrorKey.networkConfiguration:
        return l10n.walletErrorNetworkConfiguration;
      case WalletErrorKey.walletBusy:
        return l10n.walletErrorWalletBusy;
      case WalletErrorKey.incorrectPassword:
        return l10n.walletErrorIncorrectPassword;
      case WalletErrorKey.privateKeyWalletBackup:
        return l10n.exportPrivateKeyAccount;
      case WalletErrorKey.walletUnlockCloudBackup:
        return l10n.walletErrorUnlockCloudBackup;
      case WalletErrorKey.networkBusy:
        return l10n.walletErrorNetworkBusy;
      case WalletErrorKey.priceMoved:
        return l10n.walletErrorPriceMoved;
      case WalletErrorKey.priceMovedRaiseSlippage:
        return l10n.walletErrorPriceMovedRaiseSlippage;
      case WalletErrorKey.rentExemptMinimum:
        return l10n.walletErrorRentExemptMinimum;
      case WalletErrorKey.insufficientBalance:
        return l10n.walletErrorInsufficientBalance;
      case WalletErrorKey.transactionRejected:
        return l10n.walletErrorTransactionRejected;
      case WalletErrorKey.noSwapRoute:
        return l10n.walletErrorNoSwapRoute;
      case WalletErrorKey.swapQuoteUnavailable:
        return l10n.walletErrorSwapQuoteUnavailable;
      case WalletErrorKey.swapQuoteExpired:
        return l10n.walletErrorSwapQuoteExpired;
      case WalletErrorKey.invalidValue:
        return l10n.walletErrorInvalidValue;
      case WalletErrorKey.signingUnavailable:
        return l10n.walletErrorSigningUnavailable;
      case WalletErrorKey.importedSolanaPromotionUnavailable:
        return l10n.privateKeySolanaPromotionUnavailable;
      case WalletErrorKey.mnemonicMpcUnavailable:
        return l10n.mnemonicMpcUnavailable;
      case WalletErrorKey.promotionIdentityChanged:
        return l10n.privateKeyPromotionIdentityChanged;
      case WalletErrorKey.swapsUnsupportedNetwork:
        return l10n.walletErrorSwapsUnsupportedNetwork;
      case WalletErrorKey.swapServiceUnavailable:
        return l10n.walletErrorSwapServiceUnavailable;
      case WalletErrorKey.swapRejected:
        return l10n.walletErrorSwapRejected;
      case WalletErrorKey.invalidSwapRequest:
        return l10n.walletErrorInvalidSwapRequest;
      case WalletErrorKey.swapsTemporarilyUnavailable:
        return l10n.walletErrorSwapsTemporarilyUnavailable;
      case WalletErrorKey.invalidRpcUrl:
        return l10n.walletErrorInvalidRpcUrl;
      case WalletErrorKey.noInternet:
        return l10n.walletErrorNoInternet;
      case WalletErrorKey.serverUnavailable:
        return l10n.walletErrorServerUnavailable;
      case WalletErrorKey.requestTimedOut:
        return l10n.walletErrorRequestTimedOut;
      case WalletErrorKey.genericRetry:
        return l10n.walletErrorGenericRetry;
      case null:
        return message;
    }
  }

  /// Map any thrown object to a [WalletError]. Pure and side-effect free so it
  /// is trivially unit-testable; logging happens at the display boundary.
  factory WalletError.from(Object error) {
    if (error is WalletError) return error;
    if (error is SwapError) return _fromSwapError(error);
    if (error is LibwalletException) return _fromLibwalletException(error);
    if (error is AtOnlinePlatformException) return _fromAtOnline(error);
    if (error is FormatException) {
      return WalletError(
        message: 'Check the value entered.',
        key: WalletErrorKey.invalidValue,
        raw: error.toString(),
      );
    }
    // Plain exceptions: SocketException / TimeoutException / StateError /
    // custom app exceptions whose toString() is already a bare message.
    final raw = error.toString();
    final matched = _matchMessage(raw);
    return WalletError(
      message: matched?.message ?? _generic.message,
      raw: raw,
      key: matched?.key ?? _generic.key,
    );
  }

  static WalletError _fromSwapError(SwapError e) {
    // Providers sometimes wrap specific failures in provider_unavailable.
    final byMessage = _matchMessage(e.message);
    final byCode = _swapCodeMessages[e.code];
    final genericProviderCode =
        e.code == 'provider_unavailable' || e.code == 'provider_bad_request';
    final friendly =
        (genericProviderCode ? byMessage ?? byCode : byCode ?? byMessage) ??
        _generic;
    return WalletError(
      message: friendly.message,
      raw: e.toString(),
      code: e.code,
      key: friendly.key,
    );
  }

  static WalletError _fromLibwalletException(LibwalletException e) {
    // Stable transport/RPC codes we can trust win over message text.
    if (_silentCodes.contains(e.code)) {
      return WalletError(
        message: 'Request cancelled.',
        raw: e.toString(),
        code: e.code,
        key: WalletErrorKey.requestCancelled,
        silent: true,
      );
    }
    final byCode = _codeMessages[e.code];
    if (byCode != null) {
      return WalletError(
        message: byCode.message,
        raw: _rawOf(e),
        code: e.code,
        key: byCode.key,
      );
    }
    // Otherwise the reason lives in the message (chain/RPC-forwarded or a
    // libwallet-generated string).
    final byMessage = _matchMessage(e.message);
    return WalletError(
      message: byMessage?.message ?? _generic.message,
      raw: _rawOf(e),
      code: e.code,
      key: byMessage?.key ?? _generic.key,
    );
  }

  static WalletError _fromAtOnline(AtOnlinePlatformException e) {
    // toString() is unhelpful ("Instance of AtOnlinePlatformException"); the
    // server payload lives in .data.
    final raw = '${e.data}';
    final matched = _matchMessage(raw);
    return WalletError(
      message: matched?.message ?? 'Something went wrong. Please try again.',
      raw: raw,
      key: matched?.key ?? WalletErrorKey.genericRetry,
    );
  }

  /// The raw detail for a [LibwalletException] — prefer the message (which
  /// carries the chain/RPC text), falling back to the full toString().
  static String _rawOf(LibwalletException e) =>
      e.message.trim().isNotEmpty ? e.message : e.toString();

  /// First matching friendly message for [text], or `null`. Case-insensitive.
  static _FriendlyMessage? _matchMessage(String text) {
    final s = text.toLowerCase();
    for (final rule in _messageRules) {
      if (s.contains(rule.$1)) return rule.$2;
    }
    return null;
  }

  @override
  String toString() =>
      'WalletError(code: $code, silent: $silent, message: $message)';
}

// ---------------------------------------------------------------------------
// Rule tables — the single place to add / rename a mapping.
// ---------------------------------------------------------------------------

/// Codes the user triggered themselves — do not surface.
const Set<String> _silentCodes = {'4001'}; // apirouter: user rejected request.

typedef _FriendlyMessage = ({WalletErrorKey key, String message});

const _FriendlyMessage _generic = (
  key: WalletErrorKey.genericRetry,
  message: 'Something went wrong. Please try again.',
);

/// Stable libwallet transport / JSON-RPC codes we trust over message text.
/// Deliberately excludes generic codes (400/500) whose real reason lives in
/// the message.
const Map<String, _FriendlyMessage> _codeMessages = {
  '4902': (
    key: WalletErrorKey.unsupportedNetwork,
    message: "This network isn't supported yet.",
  ),
  '-32602': (
    key: WalletErrorKey.networkConfiguration,
    message: 'Network configuration problem. Check the RPC settings.',
  ),
  '503': (
    key: WalletErrorKey.walletBusy,
    message: 'The wallet is busy. Please try again.',
  ),
};

/// Stable [SwapError.code] values (see swap_quote.dart). Safe to branch on.
const Map<String, _FriendlyMessage> _swapCodeMessages = {
  'no_route': (
    key: WalletErrorKey.noSwapRoute,
    message: 'No swap route available right now.',
  ),
  'no_liquidity': (
    key: WalletErrorKey.noSwapRoute,
    message: 'No swap route for this pair right now.',
  ),
  'unsupported_token_pair': (
    key: WalletErrorKey.noSwapRoute,
    message: 'No swap route for this pair right now.',
  ),
  'unsupported_chain': (
    key: WalletErrorKey.swapsUnsupportedNetwork,
    message: "Swaps aren't supported on this network.",
  ),
  'slippage_exceeded': (
    key: WalletErrorKey.priceMovedRaiseSlippage,
    message: 'The price moved. Try again or raise the slippage.',
  ),
  'quote_expired': (
    key: WalletErrorKey.swapQuoteExpired,
    message: 'That quote expired. Please try again.',
  ),
  'quote_not_found': (
    key: WalletErrorKey.swapQuoteExpired,
    message: 'That quote expired. Please try again.',
  ),
  'provider_unavailable': (
    key: WalletErrorKey.swapServiceUnavailable,
    message: 'The swap service is unavailable. Please try again.',
  ),
  'provider_bad_request': (
    key: WalletErrorKey.swapRejected,
    message: 'That swap was rejected. Try a different amount or token.',
  ),
  'invalid_request': (
    key: WalletErrorKey.invalidSwapRequest,
    message: "Couldn't prepare this swap. Please try again.",
  ),
  'missing_api_key': (
    key: WalletErrorKey.swapsTemporarilyUnavailable,
    message: 'Swaps are temporarily unavailable.',
  ),
};

/// Ordered message-substring rules (lower-cased needle → friendly message).
/// Order matters: put specific patterns before general ones. Device-transfer
/// tokens are intentionally left to [LibwalletBackend.friendlyTransferError],
/// which has richer transfer-specific copy and disambiguates 'timeout' /
/// 'declined'.
const List<(String, _FriendlyMessage)> _messageRules = [
  (
    'mnemonic_rollback_incomplete',
    (
      key: WalletErrorKey.mnemonicRollbackIncomplete,
      message:
          'Wallet setup did not finish. Keep your recovery words and check Manage wallets before retrying.',
    ),
  ),
  (
    'backup_rollback_incomplete',
    (
      key: WalletErrorKey.backupRollbackIncomplete,
      message:
          'Restore did not finish. Keep your backup and check Manage wallets before retrying.',
    ),
  ),
  (
    'wallet_operation_changed',
    (
      key: WalletErrorKey.operationChanged,
      message: 'The account or network changed. Review again.',
    ),
  ),
  (
    'batch_partial_broadcast',
    (
      key: WalletErrorKey.partialBroadcast,
      message:
          'Some transactions were submitted. Check Activity before retrying.',
    ),
  ),
  (
    'password_update_incomplete',
    (
      key: WalletErrorKey.passwordUpdateIncomplete,
      message: 'Password update incomplete. Keep both passwords and retry.',
    ),
  ),
  (
    'promotemnemonic: curve ed25519 not yet supported',
    (
      key: WalletErrorKey.mnemonicMpcUnavailable,
      message:
          'Importing a Solana recovery phrase as an MPC wallet is not supported in this version yet.',
    ),
  ),
  (
    'imported_solana_promotion_unavailable',
    (
      key: WalletErrorKey.importedSolanaPromotionUnavailable,
      message:
          'MPC upgrade is temporarily unavailable for imported Solana accounts.',
    ),
  ),
  (
    'imported_promotion_identity_changed',
    (
      key: WalletErrorKey.promotionIdentityChanged,
      message: 'The account changed during MPC upgrade. Contact support.',
    ),
  ),
  (
    'input value is too low',
    (
      key: WalletErrorKey.swapQuoteUnavailable,
      message: 'No quote available for this token and amount right now.',
    ),
  ),
  (
    'token reference required',
    (
      key: WalletErrorKey.invalidSwapRequest,
      message: "Couldn't prepare this swap. Please try again.",
    ),
  ),
  (
    'signing committee',
    (
      key: WalletErrorKey.signingUnavailable,
      message: "Couldn't authorize this transaction. Please try again.",
    ),
  ),
  (
    'resource temporarily unavailable',
    (
      key: WalletErrorKey.networkBusy,
      message: 'The network was busy. Please try again.',
    ),
  ),
  (
    'too many requests',
    (
      key: WalletErrorKey.networkBusy,
      message: 'The network was busy. Please try again.',
    ),
  ),
  // Auth / unlock (libwallet-generated).
  (
    'private_key_wallet_backup_unavailable',
    (
      key: WalletErrorKey.privateKeyWalletBackup,
      message:
          'Imported accounts use private-key export in Manage Accounts. Select a password-protected wallet for a wallet backup.',
    ),
  ),
  (
    'wrong password',
    (key: WalletErrorKey.incorrectPassword, message: 'Incorrect password.'),
  ),
  (
    'wrong storekey',
    (
      key: WalletErrorKey.walletUnlockCloudBackup,
      message:
          'Could not unlock this wallet. Try restoring it from cloud backup.',
    ),
  ),
  // Chain-forwarded, deterministic.
  (
    'blockhash not found',
    (
      key: WalletErrorKey.networkBusy,
      message: 'The network was busy. Please try again.',
    ),
  ),
  (
    'block height exceeded',
    (
      key: WalletErrorKey.networkBusy,
      message: 'The network was busy. Please try again.',
    ),
  ),
  (
    'exceeds desired slippage',
    (
      key: WalletErrorKey.priceMoved,
      message: 'The price moved too much. Please try again.',
    ),
  ),
  (
    'slippage',
    (
      key: WalletErrorKey.priceMoved,
      message: 'The price moved too much. Please try again.',
    ),
  ),
  // Rent exemption: sending would drop the account below the minimum SOL it
  // must keep to stay open. libwallet points at Transaction:maxSendable, which
  // the send screen exposes as the MAX button.
  (
    'rent-exempt',
    (
      key: WalletErrorKey.rentExemptMinimum,
      message:
          'Sending this much would leave too little SOL to keep your account open. '
          'Send a little less, or tap MAX to send the most you safely can.',
    ),
  ),
  (
    'not enough balance',
    (
      key: WalletErrorKey.insufficientBalance,
      message: "You don't have enough balance to cover this transaction.",
    ),
  ),
  (
    'insufficient',
    (
      key: WalletErrorKey.insufficientBalance,
      message: "You don't have enough balance to cover this transaction.",
    ),
  ),
  (
    'custom program error',
    (
      key: WalletErrorKey.transactionRejected,
      message: 'The transaction was rejected on-chain.',
    ),
  ),
  (
    'error processing instruction',
    (
      key: WalletErrorKey.transactionRejected,
      message: 'The transaction was rejected on-chain.',
    ),
  ),
  // Swap routing (aggregator strings).
  (
    'failed to get quotes',
    (
      key: WalletErrorKey.noSwapRoute,
      message: 'No swap route available right now.',
    ),
  ),
  (
    'no route',
    (
      key: WalletErrorKey.noSwapRoute,
      message: 'No swap route available right now.',
    ),
  ),
  // RPC configuration (libwallet-generated).
  ('rpc url', (key: WalletErrorKey.invalidRpcUrl, message: 'Invalid RPC URL.')),
  // Network / client-side.
  (
    'socketexception',
    (key: WalletErrorKey.noInternet, message: 'No internet connection.'),
  ),
  (
    'failed host lookup',
    (key: WalletErrorKey.noInternet, message: 'No internet connection.'),
  ),
  (
    'no address associated',
    (key: WalletErrorKey.noInternet, message: 'No internet connection.'),
  ),
  (
    'connection refused',
    (
      key: WalletErrorKey.serverUnavailable,
      message: 'Server unavailable. Please try again later.',
    ),
  ),
  (
    'connection reset',
    (
      key: WalletErrorKey.serverUnavailable,
      message: 'Server unavailable. Please try again later.',
    ),
  ),
  (
    'timeoutexception',
    (
      key: WalletErrorKey.requestTimedOut,
      message: 'The request timed out. Please try again.',
    ),
  ),
  (
    'timed out',
    (
      key: WalletErrorKey.requestTimedOut,
      message: 'The request timed out. Please try again.',
    ),
  ),
];

String walletErrorMessage(AppLocalizations l10n, Object error) =>
    WalletError.from(error).localizedMessage(l10n);

String walletErrorMessageForContext(BuildContext context, Object error) =>
    walletErrorMessage(AppLocalizations.of(context), error);
