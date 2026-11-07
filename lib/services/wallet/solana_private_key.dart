import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../solana_common.dart';

class NormalizedSolanaPrivateKey {
  final String seedHex;
  final String address;

  const NormalizedSolanaPrivateKey({
    required this.seedHex,
    required this.address,
  });
}

class NormalizedEthereumPrivateKey {
  final String privateKeyHex;

  const NormalizedEthereumPrivateKey({required this.privateKeyHex});
}

/// Normalize a standard Ethereum secp256k1 private key. Ethereum exports use a
/// 32-byte hexadecimal scalar, commonly prefixed with `0x`.
NormalizedEthereumPrivateKey normalizeEthereumPrivateKey(String input) {
  final value = input.trim();
  final hex = value.startsWith('0x') ? value.substring(2) : value;
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) {
    throw const FormatException(
      'An Ethereum private key must be a 32-byte hexadecimal value',
    );
  }
  final scalar = BigInt.parse(hex, radix: 16);
  final curveOrder = BigInt.parse(
    'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141',
    radix: 16,
  );
  if (scalar == BigInt.zero || scalar >= curveOrder) {
    throw const FormatException('Invalid Ethereum private key scalar');
  }
  return NormalizedEthereumPrivateKey(privateKeyHex: hex.toLowerCase());
}

/// Accept the formats commonly exported by Solana wallets and normalize them
/// to a standard 32-byte Ed25519 seed, imported with libwallet's `format: seed`:
///
/// - base58-encoded 32-byte seed or 64-byte secret key;
/// - JSON byte array (32 or 64 values);
/// - 32/64-byte hexadecimal string, with an optional `0x` prefix.
///
/// A 64-byte Solana secret key is `seed || publicKey`. Its public half is
/// verified before the seed is accepted, preventing a malformed export from
/// silently importing a different address.
Future<NormalizedSolanaPrivateKey> normalizeSolanaPrivateKey(
  String input,
) async {
  final value = input.trim();
  if (value.isEmpty) throw const FormatException('Private key is empty');

  final bytes = _decodePrivateKey(value);
  if (bytes.length != 32 && bytes.length != 64) {
    throw const FormatException(
      'A Solana private key must contain 32 or 64 bytes',
    );
  }

  final seed = Uint8List.fromList(bytes.take(32).toList(growable: false));
  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  final publicKey = Uint8List.fromList(
    (await keyPair.extractPublicKey()).bytes,
  );

  if (bytes.length == 64) {
    final embeddedPublic = bytes.sublist(32);
    if (!_bytesEqual(embeddedPublic, publicKey)) {
      throw const FormatException(
        'The private key does not match its embedded public key',
      );
    }
  }

  return NormalizedSolanaPrivateKey(
    seedHex: _hexEncode(seed),
    address: base58Encode(publicKey),
  );
}

Uint8List _decodePrivateKey(String value) {
  if (value.startsWith('[')) {
    final decoded = jsonDecode(value);
    if (decoded is! List ||
        decoded.any((item) => item is! int || item < 0 || item > 255)) {
      throw const FormatException('Invalid Solana JSON private key');
    }
    return Uint8List.fromList(decoded.cast<int>());
  }

  final hex = value.startsWith('0x') ? value.substring(2) : value;
  if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex) &&
      (hex.length == 64 || hex.length == 128)) {
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  try {
    return base58Decode(value);
  } on FormatException {
    throw const FormatException('Invalid Solana private key');
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

String _hexEncode(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
