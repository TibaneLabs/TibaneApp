import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/solana_common.dart';
import 'package:tibaneapp/services/wallet/solana_private_key.dart';

void main() {
  const seedHex =
      '9d61b19deffd5a60ba844af492ec2cc4'
      '4449c5697b326919703bac031cae7f60';
  const publicHex =
      'd75a980182b10ab7d54bfed3c964073a'
      '0ee172f3daa62325af021a68f707511a';

  List<int> hexBytes(String value) => [
    for (var i = 0; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ];

  test('accepts a 32-byte hexadecimal ed25519 seed', () async {
    final normalized = await normalizeSolanaPrivateKey(seedHex);
    expect(normalized.seedHex, seedHex);
    expect(
      normalized.address,
      base58Encode(Uint8List.fromList(hexBytes(publicHex))),
    );
  });

  test('accepts and verifies a standard 64-byte base58 secret key', () async {
    final secret = [...hexBytes(seedHex), ...hexBytes(publicHex)];
    final normalized = await normalizeSolanaPrivateKey(
      base58Encode(Uint8List.fromList(secret)),
    );
    expect(normalized.seedHex, seedHex);
  });

  test('accepts a JSON byte-array export', () async {
    final secret = [...hexBytes(seedHex), ...hexBytes(publicHex)];
    final normalized = await normalizeSolanaPrivateKey(jsonEncode(secret));
    expect(normalized.seedHex, seedHex);
  });

  test('rejects a mismatched public half', () async {
    final secret = [...hexBytes(seedHex), ...List<int>.filled(32, 0)];
    expect(
      () => normalizeSolanaPrivateKey(base58Encode(Uint8List.fromList(secret))),
      throwsFormatException,
    );
  });

  test('rejects keys with an unsupported byte length', () async {
    expect(() => normalizeSolanaPrivateKey('1111'), throwsFormatException);
  });

  test('normalizes a standard Ethereum private key', () {
    final normalized = normalizeEthereumPrivateKey(
      '0x0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF',
    );
    expect(
      normalized.privateKeyHex,
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );
  });

  test('rejects zero and out-of-range Ethereum private keys', () {
    expect(
      () => normalizeEthereumPrivateKey(List.filled(64, '0').join()),
      throwsFormatException,
    );
    expect(
      () => normalizeEthereumPrivateKey(
        'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
      ),
      throwsFormatException,
    );
  });

  test('rejects malformed Ethereum private keys', () {
    expect(() => normalizeEthereumPrivateKey('0x1234'), throwsFormatException);
    expect(
      () => normalizeEthereumPrivateKey(List.filled(64, 'z').join()),
      throwsFormatException,
    );
  });
}
