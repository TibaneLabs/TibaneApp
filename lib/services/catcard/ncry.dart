import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'wire.dart';

/// The host half of CatCard's paired encrypted channel, `ncry` v2
/// (docs/PHONE-APP.md §4; reference `tools/ncry.py`).
///
/// Pairing is numeric comparison, redone on every connection and stored
/// nowhere: the host commits to its X25519 key, the device answers with a
/// fresh one, the host reveals, both derive the same keys and a six-digit
/// code, and a person compares the code on both screens. That comparison is
/// the whole defence against a relay, so the UI must show it and never
/// pre-accept.
///
/// After pairing each direction is ChaCha20-Poly1305 under its own key with
/// a counter nonce, counted from zero per direction.

const String _commitLabel = 'catcard-pair-v2/commit';
const String _keysInfo = 'catcard-ncry-v2';
const String _codeInfo = 'catcard-pair-v2/code';
const int _codeModulus = 1000000;

const int ncryKeyLen = 32;
const int ncryTagLen = 16;

/// Most plaintext one sealed record carries, opcode included.
const int ncryPlainMax = 1024;

final X25519 _x25519 = X25519();
final Chacha20 _aead = Chacha20.poly1305Aead();

/// Six digits, zero padded, grouped the way both screens show them: `123 456`.
String pairingCodeText(int code) {
  final s = code.toString().padLeft(6, '0');
  return '${s.substring(0, 3)} ${s.substring(3)}';
}

/// `SHA-256(label ‖ host_pub)`: the `PairCommit` payload.
Future<Uint8List> pairingCommitment(List<int> hostPub) async {
  final h = await Sha256().hash([...utf8.encode(_commitLabel), ...hostPub]);
  return Uint8List.fromList(h.bytes);
}

/// A sealed record failed to authenticate. The device tears the session down
/// on its side for the same reason, so the session is over.
class NcryAuthException extends CatCardException {
  NcryAuthException() : super('the paired channel failed to authenticate');
}

/// One end of an established channel, with the pairing code its handshake
/// produced.
class NcrySession {
  NcrySession(this._sendKey, this._recvKey, this.code);

  final SecretKey _sendKey;
  final SecretKey _recvKey;

  /// The six-digit code, 0..999999.
  final int code;

  int _sendCounter = 0;
  int _recvCounter = 0;

  String get codeText => pairingCodeText(code);

  /// The schedule both sides run once they share a secret: the transcript in
  /// wire order (`commit ‖ device_pub ‖ host_pub`) salts HKDF; the host sends
  /// under the first 32 bytes and receives under the next 32; eight more
  /// bytes under a second label are the code. This is the host's view.
  static Future<NcrySession> fromHandshake({
    required List<int> shared,
    required List<int> commit,
    required List<int> devicePub,
    required List<int> hostPub,
  }) async {
    final secret = SecretKey(shared);
    final transcript = Uint8List.fromList([...commit, ...devicePub, ...hostPub]);
    final okm = await Hkdf(hmac: Hmac.sha256(), outputLength: 64).deriveKey(
      secretKey: secret,
      nonce: transcript,
      info: utf8.encode(_keysInfo),
    );
    final okmBytes = await okm.extractBytes();
    final codeKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 8).deriveKey(
      secretKey: secret,
      nonce: transcript,
      info: utf8.encode(_codeInfo),
    );
    // Big-endian u64 mod 10^6, folded a byte at a time: a Dart int is signed,
    // so reading the eight bytes as one integer would go negative for half
    // of all codes and the modulo with it.
    var code = 0;
    for (final b in await codeKey.extractBytes()) {
      code = (code * 256 + b) % _codeModulus;
    }
    return NcrySession(
      SecretKey(okmBytes.sublist(0, 32)),
      SecretKey(okmBytes.sublist(32, 64)),
      code,
    );
  }

  /// The other end's view of this session: what it sends we receive. For
  /// tests that play the device.
  @visibleForTesting
  NcrySession swapped() => NcrySession(_recvKey, _sendKey, code);

  static Uint8List _nonce(int counter) {
    final n = Uint8List(12);
    ByteData.view(n.buffer).setUint64(0, counter, Endian.little);
    return n;
  }

  /// `ciphertext ‖ tag` for [plain], under the next send nonce.
  Future<Uint8List> seal(List<int> plain) async {
    if (plain.length > ncryPlainMax) {
      throw ArgumentError('sealed plaintext over $ncryPlainMax bytes');
    }
    final box = await _aead.encrypt(
      plain,
      secretKey: _sendKey,
      nonce: _nonce(_sendCounter),
    );
    _sendCounter++;
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  /// The plaintext of [record], under the next receive nonce.
  Future<Uint8List> open(List<int> record) async {
    if (record.length < ncryTagLen) {
      throw CatCardProtocolException('sealed record shorter than its tag');
    }
    final ct = record.sublist(0, record.length - ncryTagLen);
    final tag = record.sublist(record.length - ncryTagLen);
    final box = SecretBox(ct, nonce: _nonce(_recvCounter), mac: Mac(tag));
    final List<int> plain;
    try {
      plain = await _aead.decrypt(box, secretKey: _recvKey);
    } on SecretBoxAuthenticationError {
      throw NcryAuthException();
    }
    _recvCounter++;
    return Uint8List.fromList(plain);
  }
}

/// The host's half of the handshake: commit first, reveal after the device
/// answers.
class PairingInitiator {
  PairingInitiator._(this._keyPair, this.publicKey, this.commit);

  final SimpleKeyPair _keyPair;

  /// `host_pub`, the `PairReveal` payload.
  final Uint8List publicKey;

  /// The `PairCommit` payload.
  final Uint8List commit;

  /// A fresh ephemeral key, or the one [privateKey] gives (tests only).
  static Future<PairingInitiator> create({List<int>? privateKey}) async {
    final kp = privateKey == null
        ? await _x25519.newKeyPair()
        : await _x25519.newKeyPairFromSeed(privateKey);
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return PairingInitiator._(kp, pub, await pairingCommitment(pub));
  }

  /// X25519 against [peerPub]; refuses a small-order peer (all-zero result).
  Future<List<int>> sharedSecretWith(List<int> peerPub) async {
    if (peerPub.length != ncryKeyLen) {
      throw CatCardProtocolException('peer key is not 32 bytes');
    }
    final shared = await _x25519.sharedSecretKey(
      keyPair: _keyPair,
      remotePublicKey: SimplePublicKey(peerPub, type: KeyPairType.x25519),
    );
    final bytes = await shared.extractBytes();
    if (bytes.every((b) => b == 0)) {
      throw CatCardProtocolException('small-order peer key');
    }
    return bytes;
  }

  /// Derive the host [NcrySession] (and its code) from the device's key.
  Future<NcrySession> finish(List<int> devicePub) async =>
      NcrySession.fromHandshake(
        shared: await sharedSecretWith(devicePub),
        commit: commit,
        devicePub: devicePub,
        hostPub: publicKey,
      );
}
