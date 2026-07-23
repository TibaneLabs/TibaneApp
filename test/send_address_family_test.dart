import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/screens/wallet/send_screen.dart';
import 'package:tibaneapp/services/solana_common.dart';

/// Build a legacy base58 address with a chosen version byte.
/// [detectSendAddressFamily] / [bitcoinCoinsForAddress] only inspect the decoded
/// length (25) and the version byte — not the checksum — so a deterministic
/// 25-byte payload is a faithful stand-in for a real address in these tests.
String legacyAddress(int version) =>
    base58Encode(Uint8List.fromList([version, ...List.filled(24, 0)]));

// Example valid-charset bech32 / CashAddr strings (prefix + payload; the family
// detector matches on charset and length, not checksum).
const _btcBech32 = 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4';
const _ltcBech32 = 'ltc1qw508d6qejxtdg4y5r3zarvary0c5xw7kwn7lls';
const _bchCashAddr = 'bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a';

void main() {
  group('bitcoinCoinsForAddress', () {
    test('bech32 prefixes resolve to a single coin', () {
      expect(bitcoinCoinsForAddress(_btcBech32), {BitcoinCoin.bitcoin});
      expect(bitcoinCoinsForAddress(_ltcBech32), {BitcoinCoin.litecoin});
    });

    test('CashAddr resolves to Bitcoin Cash', () {
      expect(bitcoinCoinsForAddress(_bchCashAddr), {BitcoinCoin.bitcoinCash});
    });

    test('legacy P2PKH/P2SH is ambiguous between BTC and BCH', () {
      expect(bitcoinCoinsForAddress(legacyAddress(0)), {
        BitcoinCoin.bitcoin,
        BitcoinCoin.bitcoinCash,
      });
      expect(bitcoinCoinsForAddress(legacyAddress(5)), {
        BitcoinCoin.bitcoin,
        BitcoinCoin.bitcoinCash,
      });
    });

    test('Dogecoin and Litecoin legacy version bytes resolve uniquely', () {
      expect(bitcoinCoinsForAddress(legacyAddress(30)), {BitcoinCoin.dogecoin});
      expect(bitcoinCoinsForAddress(legacyAddress(22)), {BitcoinCoin.dogecoin});
      expect(bitcoinCoinsForAddress(legacyAddress(48)), {BitcoinCoin.litecoin});
      expect(bitcoinCoinsForAddress(legacyAddress(50)), {BitcoinCoin.litecoin});
    });

    test('non-bitcoin-family input yields an empty set', () {
      expect(bitcoinCoinsForAddress('0x1234567890abcdef'), isEmpty);
      expect(bitcoinCoinsForAddress(''), isEmpty);
      expect(bitcoinCoinsForAddress('not an address'), isEmpty);
    });
  });

  group('cross-coin send guard (F1)', () {
    // Mirrors the guard in _recipientNetworkWarning: block when the recipient is
    // provably a *different* coin than the active account; never block a
    // matching or genuinely-ambiguous address.
    bool blocks(String activeChain, String recipient) {
      final active = bitcoinCoinForChain(activeChain)!;
      final possible = bitcoinCoinsForAddress(recipient);
      return possible.isNotEmpty && !possible.contains(active);
    }

    test('BTC address on a Litecoin account is blocked', () {
      expect(blocks('litecoin', _btcBech32), isTrue);
    });

    test('LTC address on a Bitcoin account is blocked', () {
      expect(blocks('bitcoin', _ltcBech32), isTrue);
    });

    test('Dogecoin address on a Bitcoin account is blocked', () {
      expect(blocks('bitcoin', legacyAddress(30)), isTrue);
    });

    test('segwit BTC address on a Bitcoin Cash account is blocked', () {
      // BCH has no segwit — a bc1 address is never a valid BCH recipient.
      expect(blocks('bitcoin-cash', _btcBech32), isTrue);
    });

    test('a matching coin is never blocked', () {
      expect(blocks('bitcoin', _btcBech32), isFalse);
      expect(blocks('litecoin', _ltcBech32), isFalse);
      expect(blocks('litecoin', legacyAddress(48)), isFalse);
    });

    test('BTC legacy on a Bitcoin Cash account is NOT blocked (ambiguous pair)',
        () {
      // Documents the known limitation: BTC and BCH legacy addresses are
      // indistinguishable, so this pair is left to the server validator.
      expect(blocks('bitcoin-cash', legacyAddress(0)), isFalse);
      expect(blocks('bitcoin', legacyAddress(0)), isFalse);
    });
  });

  group('detectSendAddressFamily accepts short legacy addresses (F4)', () {
    test('a legacy address under 32 chars is recognized, not rejected', () {
      // A leading-zero (version 0x00) BTC P2PKH base58-encodes short; the old
      // `length < 32` guard wrongly rejected these.
      final shortLegacy = legacyAddress(0);
      expect(shortLegacy.length, lessThan(32));
      expect(detectSendAddressFamily(shortLegacy), SendAddressFamily.bitcoin);
    });
  });
}
