import 'dart:io' show SocketException;

import 'package:atonline_api/atonline_api.dart' show AtOnlinePlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show LibwalletException, SwapError;
import 'package:tibaneapp/utils/wallet_error.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:flutter/widgets.dart';

/// Unit tests for [WalletError.from] — the single point that maps raw
/// libwallet / chain / aggregator errors to friendly messages while keeping
/// the raw text for debugging. See ERROR_DISPLAY_AUDIT.md.
void main() {
  group('SwapError (stable code — swap quote failures)', () {
    test('maps no_liquidity to a friendly message and keeps the code', () {
      final we = WalletError.from(
        const SwapError(code: 'no_liquidity', message: 'Failed to get quotes'),
      );
      expect(we.message, 'No swap route for this pair right now.');
      expect(we.code, 'no_liquidity');
      expect(we.silent, isFalse);
    });

    test('maps slippage_exceeded', () {
      final we = WalletError.from(
        const SwapError(code: 'slippage_exceeded', message: 'x'),
      );
      expect(we.message, contains('price moved'));
      expect(we.code, 'slippage_exceeded');
    });

    test('quote_expired and quote_not_found share the refetch message', () {
      expect(
        WalletError.from(
          const SwapError(code: 'quote_expired', message: 'x'),
        ).message,
        contains('quote expired'),
      );
      expect(
        WalletError.from(
          const SwapError(code: 'quote_not_found', message: 'x'),
        ).message,
        contains('quote expired'),
      );
    });

    test('preserves the raw SwapError text for debugging', () {
      final we = WalletError.from(
        const SwapError(code: 'no_liquidity', message: 'Failed to get quotes'),
      );
      expect(we.raw, contains('no_liquidity'));
      expect(we.raw, contains('Failed to get quotes'));
    });

    test('unknown swap code falls back to message-substring matching', () {
      final we = WalletError.from(
        const SwapError(
          code: 'totally_new_code',
          message: 'insufficient funds',
        ),
      );
      expect(we.message, contains("don't have enough balance"));
      expect(we.code, 'totally_new_code'); // code still preserved
    });
  });

  group('LibwalletException — stable codes win over message', () {
    test('4001 (user rejected) is silent', () {
      final we = WalletError.from(
        const LibwalletException(
          message: 'User rejected the request.',
          code: '4001',
        ),
      );
      expect(we.silent, isTrue);
      expect(we.code, '4001');
    });

    test('4902 maps to unsupported network', () {
      final we = WalletError.from(
        const LibwalletException(
          message: 'Unrecognized chain ID.',
          code: '4902',
        ),
      );
      expect(we.message, contains("isn't supported"));
      expect(we.silent, isFalse);
    });

    test('-32602 maps to a network-config message', () {
      final we = WalletError.from(
        const LibwalletException(message: 'Invalid params', code: '-32602'),
      );
      expect(we.message, contains('Network configuration'));
    });

    test('503 maps to wallet-busy', () {
      final we = WalletError.from(
        const LibwalletException(message: 'handle shutting down', code: '503'),
      );
      expect(we.message, contains('busy'));
    });

    test('generic code 500 falls through to the message', () {
      // The real reason for a 500 lives in the message, not the code.
      final we = WalletError.from(
        const LibwalletException(
          message: 'okx solana broadcast: insufficient lamports',
          code: '500',
        ),
      );
      expect(we.message, contains("don't have enough balance"));
      expect(we.code, '500');
    });
  });

  group('LibwalletException — reason carried in .message (Fact A)', () {
    // Real strings observed in libwallet/wltswap/okx_test.go and friends.
    final cases = <String, String>{
      'Transaction simulation failed: Blockhash not found':
          'The network was busy. Please try again.',
      'insufficient lamports':
          "You don't have enough balance to cover this transaction.",
      'exceeds desired slippage limit':
          'The price moved too much. Please try again.',
      'Transaction simulation failed: Error processing Instruction 5: '
              'custom program error: 0xb':
          'The transaction was rejected on-chain.',
      'wrong password': 'Incorrect password.',
      'RPC URL must use https': 'Invalid RPC URL.',
      // Rent-exemption error from the send flow (real string from libwallet).
      'sending 9830254 lamports + fee 5000 would leave 790880 lamports on the '
              'sender, below the rent-exempt minimum 890880. Use '
              'Transaction:maxSendable to compute a safe amount.':
          'Sending this much would leave too little SOL to keep your account '
          'open. Send a little less, or tap MAX to send the most you '
          'safely can.',
    };
    cases.forEach((raw, friendly) {
      test('"$raw" -> "$friendly"', () {
        final we = WalletError.from(
          LibwalletException(message: raw, code: '500'),
        );
        expect(we.message, friendly);
        expect(we.raw, raw); // raw always preserved
      });
    });

    test('matching is case-insensitive', () {
      final we = WalletError.from(
        const LibwalletException(message: 'BLOCKHASH NOT FOUND', code: '0'),
      );
      expect(we.message, 'The network was busy. Please try again.');
    });

    test('unmatched native message stays in technical details only', () {
      final we = WalletError.from(
        const LibwalletException(
          message: 'Exception: some novel failure',
          code: '0',
        ),
      );
      expect(we.key, WalletErrorKey.genericRetry);
      expect(we.message, 'Something went wrong. Please try again.');
      expect(we.raw, contains('some novel failure'));
    });
  });

  group('plain Dart exceptions', () {
    test('SocketException -> no internet', () {
      final we = WalletError.from(const SocketException('Failed host lookup'));
      expect(we.message, 'No internet connection.');
      expect(we.raw, contains('SocketException'));
    });

    test('generic exception uses a friendly fallback', () {
      final we = WalletError.from(Exception('plain boom'));
      expect(we.key, WalletErrorKey.genericRetry);
      expect(we.raw, contains('plain boom'));
    });

    test('unknown StateError stays in technical details', () {
      final we = WalletError.from(StateError('nothing to export'));
      expect(we.key, WalletErrorKey.genericRetry);
      expect(we.raw, contains('nothing to export'));
    });

    test('FormatException uses a localized validation message', () {
      final we = WalletError.from(const FormatException('not valid base58'));
      expect(we.key, WalletErrorKey.invalidValue);
      expect(we.raw, contains('not valid base58'));
    });
  });

  group('AtOnlinePlatformException', () {
    test('reads the server payload into raw, not "Instance of ..."', () {
      final we = WalletError.from(
        AtOnlinePlatformException({'error': 'quota exceeded'}),
      );
      expect(we.raw, contains('quota exceeded'));
      expect(we.raw, isNot(contains('Instance of')));
    });

    test('falls back to a generic friendly message when nothing matches', () {
      final we = WalletError.from(
        AtOnlinePlatformException({'token': 'error_x'}),
      );
      expect(we.message, 'Something went wrong. Please try again.');
    });

    test('still matches known substrings inside the payload', () {
      final we = WalletError.from(
        AtOnlinePlatformException({'message': 'connection refused'}),
      );
      expect(we.message, contains('Server unavailable'));
    });
  });

  group('localized technical errors', () {
    for (final language in ['en', 'pt', 'fr', 'ja']) {
      test('mnemonic migration limitation is explicit in $language', () async {
        final l10n = await AppLocalizations.delegate.load(Locale(language));
        final error = WalletError.from(
          const LibwalletException(
            code: '400',
            message:
                'env error: promoteMnemonic: curve ed25519 not yet supported (secp256k1 only)',
          ),
        );
        expect(error.key, WalletErrorKey.mnemonicMpcUnavailable);
        expect(error.localizedMessage(l10n), l10n.mnemonicMpcUnavailable);
        expect(
          error.localizedMessage(l10n),
          isNot(l10n.walletErrorGenericRetry),
        );
      });
    }
    const raw =
        'env error: rest Crypto/Okx:quote error: OKX API error 51006 '
        'on GET /api/v6/dex/aggregator/quote: Input value is too low. '
        'Please check the token decimals or token value.';
    for (final language in ['en', 'pt', 'fr', 'ja']) {
      test(
        'quote rejection and unknown errors are localized in $language',
        () async {
          final l10n = await AppLocalizations.delegate.load(Locale(language));
          for (final error in <Object>[
            const SwapError(code: 'provider_unavailable', message: raw),
            const LibwalletException(code: '500', message: raw),
            Exception('$raw (provider_unavailable)'),
          ]) {
            final mapped = WalletError.from(error);
            expect(mapped.key, WalletErrorKey.swapQuoteUnavailable);
            expect(
              mapped.localizedMessage(l10n),
              l10n.walletErrorSwapQuoteUnavailable,
            );
            expect(mapped.localizedMessage(l10n), isNot(contains('51006')));
            expect(mapped.localizedMessage(l10n), isNot(contains('/api/')));
            expect(mapped.raw, contains(raw));
          }
          final unknown = WalletError.from(
            Exception('env error: unknown backend payload'),
          );
          expect(unknown.localizedMessage(l10n), l10n.walletErrorGenericRetry);
          final expired = WalletError.from(
            const SwapError(code: 'quote_expired', message: 'x'),
          );
          expect(
            expired.localizedMessage(l10n),
            l10n.walletErrorSwapQuoteExpired,
          );
        },
      );
    }
    test('transient RPC and signing failures have short messages', () {
      expect(
        WalletError.from(
          Exception(
            'rpc getTokenAccountsByOwner request failed: Resource temporarily unavailable (os error 35)',
          ),
        ).key,
        WalletErrorKey.networkBusy,
      );
      expect(
        WalletError.from(
          Exception(
            'tss error: signing committee: threshold must be at least 1',
          ),
        ).key,
        WalletErrorKey.signingUnavailable,
      );
      expect(
        WalletError.from(Exception('token reference required')).key,
        WalletErrorKey.invalidSwapRequest,
      );
    });
  });

  group('invariants', () {
    test('raw is never empty', () {
      for (final e in <Object>[
        Exception('x'),
        const LibwalletException(message: '', code: '500'),
        const SwapError(code: 'no_liquidity', message: ''),
        const FormatException(),
      ]) {
        expect(WalletError.from(e).raw, isNotEmpty, reason: '$e');
      }
    });

    test('only 4001 is silent among the sampled codes', () {
      expect(
        WalletError.from(
          const LibwalletException(message: 'x', code: '4001'),
        ).silent,
        isTrue,
      );
      expect(
        WalletError.from(
          const LibwalletException(message: 'x', code: '4902'),
        ).silent,
        isFalse,
      );
    });
  });
}
