/// Core Solana primitives: base58, compact-u16, PDA derivation, transaction builder.
/// No external Solana package dependency - uses only dart:typed_data and crypto.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// ─── Base58 ──────────────────────────────────────────────────────────────────

const _base58Alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
final _base58Map = () {
  final map = <int, int>{};
  for (var i = 0; i < _base58Alphabet.length; i++) {
    map[_base58Alphabet.codeUnitAt(i)] = i;
  }
  return map;
}();

Uint8List base58Decode(String input) {
  var value = BigInt.zero;
  final base = BigInt.from(58);
  for (final c in input.codeUnits) {
    final digit = _base58Map[c];
    if (digit == null) throw FormatException('Invalid base58 character: ${String.fromCharCode(c)}');
    value = value * base + BigInt.from(digit);
  }

  // Count leading '1's (= leading zero bytes)
  var leadingZeros = 0;
  for (final c in input.codeUnits) {
    if (c == 0x31) {
      leadingZeros++;
    } else {
      break;
    }
  }

  // Convert BigInt to bytes (big-endian)
  if (value == BigInt.zero) {
    return Uint8List(leadingZeros);
  }
  final hex = value.toRadixString(16);
  final hexPadded = hex.length.isOdd ? '0$hex' : hex;
  final bytes = <int>[];
  for (var i = 0; i < hexPadded.length; i += 2) {
    bytes.add(int.parse(hexPadded.substring(i, i + 2), radix: 16));
  }

  return Uint8List.fromList([...List.filled(leadingZeros, 0), ...bytes]);
}

String base58Encode(Uint8List data) {
  var value = BigInt.zero;
  for (final byte in data) {
    value = (value << 8) + BigInt.from(byte);
  }

  final result = <String>[];
  final base = BigInt.from(58);
  while (value > BigInt.zero) {
    result.add(_base58Alphabet[(value % base).toInt()]);
    value ~/= base;
  }

  for (final byte in data) {
    if (byte == 0) {
      result.add('1');
    } else {
      break;
    }
  }

  return result.reversed.join();
}

// ─── Compact-u16 encoding ────────────────────────────────────────────────────

/// Encode a length as a Solana compact-u16 (1-3 bytes)
Uint8List compactU16(int value) {
  if (value < 0x80) {
    return Uint8List.fromList([value]);
  } else if (value < 0x4000) {
    return Uint8List.fromList([
      (value & 0x7F) | 0x80,
      (value >> 7) & 0x7F,
    ]);
  } else {
    return Uint8List.fromList([
      (value & 0x7F) | 0x80,
      ((value >> 7) & 0x7F) | 0x80,
      (value >> 14) & 0x03,
    ]);
  }
}

// ─── Ed25519 curve check (for PDA derivation) ───────────────────────────────

final _edP = BigInt.two.pow(255) - BigInt.from(19);
final _edD = BigInt.from(-121665) * _modInverse(BigInt.from(121666), _edP) % _edP;

BigInt _modInverse(BigInt a, BigInt m) => a.modPow(m - BigInt.two, m);

/// Returns true if the 32-byte key is a valid ed25519 point (ON the curve).
/// For PDAs, we want this to be FALSE.
bool _isOnCurve(Uint8List key) {
  if (key.length != 32) return false;

  // Read y as little-endian, clear sign bit
  var y = BigInt.zero;
  for (var i = 0; i < 32; i++) {
    y += BigInt.from(key[i]) << (8 * i);
  }
  y &= (BigInt.one << 255) - BigInt.one;
  if (y >= _edP) return false;

  // x^2 = (y^2 - 1) * inverse(d * y^2 + 1) mod p
  final y2 = (y * y) % _edP;
  final u = (y2 - BigInt.one) % _edP;
  final v = (_edD * y2 + BigInt.one) % _edP;
  final x2 = (u * _modInverse(v, _edP)) % _edP;

  if (x2 == BigInt.zero) return true;

  // Euler's criterion: x2 is a quadratic residue iff x2^((p-1)/2) ≡ 1 mod p
  final exp = (_edP - BigInt.one) >> 1;
  return x2.modPow(exp, _edP) == BigInt.one;
}

// ─── PDA derivation ──────────────────────────────────────────────────────────

/// Derive a Program Derived Address. Returns (address, bump).
(Uint8List, int) findProgramAddress(List<Uint8List> seeds, Uint8List programId) {
  final pda = utf8.encode('ProgramDerivedAddress');
  for (var bump = 255; bump >= 0; bump--) {
    final hasher = sha256.convert([
      ...seeds.expand((s) => s),
      bump,
      ...programId,
      ...pda,
    ]);
    final hash = Uint8List.fromList(hasher.bytes);
    if (!_isOnCurve(hash)) {
      return (hash, bump);
    }
  }
  throw StateError('Could not find PDA');
}

/// Convenience: derive PDA from string seeds and base58 program ID
(String, int) findProgramAddressFromStrings(List<Uint8List> seeds, String programIdBase58) {
  final programId = base58Decode(programIdBase58);
  final (addr, bump) = findProgramAddress(seeds, programId);
  return (base58Encode(addr), bump);
}

// ─── Account metadata for instructions ───────────────────────────────────────

class AccountMeta {
  final Uint8List pubkey;
  final bool isSigner;
  final bool isWritable;

  AccountMeta(this.pubkey, {required this.isSigner, required this.isWritable});

  factory AccountMeta.fromBase58(String address, {required bool isSigner, required bool isWritable}) {
    return AccountMeta(base58Decode(address), isSigner: isSigner, isWritable: isWritable);
  }
}

// ─── Instruction ─────────────────────────────────────────────────────────────

class SolanaInstruction {
  final Uint8List programId;
  final List<AccountMeta> accounts;
  final Uint8List data;

  SolanaInstruction({
    required this.programId,
    required this.accounts,
    required this.data,
  });

  factory SolanaInstruction.fromBase58({
    required String programId,
    required List<AccountMeta> accounts,
    required Uint8List data,
  }) {
    return SolanaInstruction(
      programId: base58Decode(programId),
      accounts: accounts,
      data: data,
    );
  }
}

// ─── Transaction builder ─────────────────────────────────────────────────────

/// Build an unsigned serialized transaction ready for MWA signing.
/// The transaction has placeholder (zero) signatures that the wallet fills in.
Uint8List buildTransaction({
  required String recentBlockhash,
  required String feePayer,
  required List<SolanaInstruction> instructions,
}) {
  // Collect all unique accounts, maintaining order:
  // 1. Fee payer (signer + writable)
  // 2. Other signers (writable first, then readonly)
  // 3. Non-signers (writable first, then readonly)
  final feePayerBytes = base58Decode(feePayer);

  // Gather all account keys from instructions
  final accountMap = <String, (Uint8List, bool isSigner, bool isWritable)>{};
  accountMap[feePayer] = (feePayerBytes, true, true);

  for (final ix in instructions) {
    for (final acc in ix.accounts) {
      final key = base58Encode(acc.pubkey);
      final existing = accountMap[key];
      if (existing != null) {
        accountMap[key] = (
          acc.pubkey,
          existing.$2 || acc.isSigner,
          existing.$3 || acc.isWritable,
        );
      } else {
        accountMap[key] = (acc.pubkey, acc.isSigner, acc.isWritable);
      }
    }
    // Program ID is a readonly non-signer
    final progKey = base58Encode(ix.programId);
    accountMap.putIfAbsent(progKey, () => (ix.programId, false, false));
  }

  // Sort: fee payer first, then signers (writable, readonly), then non-signers (writable, readonly)
  final entries = accountMap.entries.toList();
  entries.sort((a, b) {
    final (_, aIsSigner, aIsWritable) = a.value;
    final (_, bIsSigner, bIsWritable) = b.value;

    // Fee payer always first
    if (a.key == feePayer) return -1;
    if (b.key == feePayer) return 1;

    // Signers before non-signers
    if (aIsSigner && !bIsSigner) return -1;
    if (!aIsSigner && bIsSigner) return 1;

    // Within same signer group: writable before readonly
    if (aIsWritable && !bIsWritable) return -1;
    if (!aIsWritable && bIsWritable) return 1;

    return 0;
  });

  final accountKeys = <Uint8List>[];
  final keyIndexMap = <String, int>{};
  var numRequiredSignatures = 0;
  var numReadonlySigned = 0;
  var numReadonlyUnsigned = 0;

  for (final entry in entries) {
    keyIndexMap[entry.key] = accountKeys.length;
    accountKeys.add(entry.value.$1);

    final isSigner = entry.value.$2;
    final isWritable = entry.value.$3;

    if (isSigner) {
      numRequiredSignatures++;
      if (!isWritable) numReadonlySigned++;
    } else {
      if (!isWritable) numReadonlyUnsigned++;
    }
  }

  // Build message
  final message = BytesBuilder();

  // Header
  message.addByte(numRequiredSignatures);
  message.addByte(numReadonlySigned);
  message.addByte(numReadonlyUnsigned);

  // Account keys
  message.add(compactU16(accountKeys.length));
  for (final key in accountKeys) {
    message.add(key);
  }

  // Recent blockhash
  message.add(base58Decode(recentBlockhash));

  // Instructions
  message.add(compactU16(instructions.length));
  for (final ix in instructions) {
    final programIdIndex = keyIndexMap[base58Encode(ix.programId)]!;
    message.addByte(programIdIndex);

    // Account indices
    message.add(compactU16(ix.accounts.length));
    for (final acc in ix.accounts) {
      message.addByte(keyIndexMap[base58Encode(acc.pubkey)]!);
    }

    // Data
    message.add(compactU16(ix.data.length));
    message.add(ix.data);
  }

  final messageBytes = message.toBytes();

  // Build full transaction: signatures + message
  final tx = BytesBuilder();
  tx.add(compactU16(numRequiredSignatures));
  // Empty signatures (64 zero bytes each)
  for (var i = 0; i < numRequiredSignatures; i++) {
    tx.add(Uint8List(64));
  }
  tx.add(messageBytes);

  return tx.toBytes();
}
