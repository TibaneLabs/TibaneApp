import 'dart:convert';
import 'dart:typed_data';

/// CatCard's USB wire protocol: the opcodes, statuses and small layouts every
/// transport carries (`catcard_usb`, docs/USB.md and docs/PHONE-APP.md in the
/// catcard repo). Byte-for-byte reference: `tools/usbclient.py` there.
///
/// Integers on the wire are little-endian throughout.

/// Message opcodes (`catcard_usb::Opcode`).
abstract final class Opcode {
  static const int ping = 0x0001;
  static const int identify = 0x0002;
  static const int readLog = 0x0012;

  /// A sealed record for the paired channel; see `ncry.dart`.
  static const int ncryMsg = 0x0041;
  static const int pairCommit = 0x0042;
  static const int pairReveal = 0x0043;
  static const int pairConfirm = 0x0044;
  static const int pairAbort = 0x0045;

  /// Host-wallet commands, inside a paired `ncryMsg` only.
  static const int hostAddresses = 0x0050;
  static const int hostSignBegin = 0x0051;
  static const int hostSignData = 0x0052;
  static const int hostSignCommit = 0x0053;
  static const int hostResult = 0x0054;
  static const int hostAbort = 0x0055;
}

/// Message statuses (`catcard_usb::Status`): the first two bytes of a reply.
abstract final class Status {
  static const int ok = 0x0000;
  static const int unknownOpcode = 0x0001;
  static const int notNow = 0x0002;
  static const int badRequest = 0x0003;
  static const int declined = 0x0004;
  static const int refused = 0x0005;
  static const int busy = 0x0006;

  static String name(int status) => switch (status) {
    ok => 'Ok',
    unknownOpcode => 'UnknownOpcode',
    notNow => 'NotNow',
    badRequest => 'BadRequest',
    declined => 'Declined',
    refused => 'Refused',
    busy => 'Busy',
    _ => 'status $status',
  };
}

/// Capability bits of `Identify` (`catcard_usb::caps`).
abstract final class Caps {
  static const int keyInjection = 1 << 0;
  static const int upgrade = 1 << 1;
  static const int debugMem = 1 << 2;
  static const int unlockPin = 1 << 3;
  static const int upgradePacked = 1 << 4;
  static const int hostWallet = 1 << 6;
  static const int pairing = 1 << 7;

  /// Bits that mean a bench build: the host can press keys or read memory.
  static const int bench = keyInjection | debugMem | unlockPin;
}

/// Device state bits of `Identify` (`catcard_usb::state`).
abstract final class DeviceState {
  static const int unlocked = 1 << 0;
  static const int blank = 1 << 1;
}

/// The protocol version this code was written against.
const int catCardProtocolVersion = 2;

/// One reply: the message status and the payload after it.
class Reply {
  const Reply(this.status, this.body);

  final int status;
  final Uint8List body;

  bool get ok => status == Status.ok;

  /// The payload as text, for a `Refused` reason.
  String get text => utf8.decode(body, allowMalformed: true);

  /// The first payload byte, or 0: the detail a `NotNow` carries.
  int get detail => body.isEmpty ? 0 : body[0];

  @override
  String toString() => 'Reply(${Status.name(status)}, ${body.length} B)';
}

/// What `Identify` answers.
class CatCardIdentity {
  const CatCardIdentity({
    required this.protocolVersion,
    required this.state,
    required this.caps,
    required this.board,
    required this.version,
  });

  final int protocolVersion;
  final int state;
  final int caps;

  /// `mk3`, `mk4`, `mk5` or `q1`.
  final String board;
  final String version;

  bool get unlocked => state & DeviceState.unlocked != 0;
  bool get blank => state & DeviceState.blank != 0;
  bool get hasPairing => caps & Caps.pairing != 0;
  bool get hasHostWallet => caps & Caps.hostWallet != 0;
  bool get isBench => caps & Caps.bench != 0;

  /// Whether an app may go on: protocol 2 and both capability bits.
  bool get usable =>
      protocolVersion == catCardProtocolVersion && hasPairing && hasHostWallet;

  /// Layout: `[u16 protocol][u8 state][u8 caps][u8 n][board][u8 m][version]`.
  static CatCardIdentity parse(Uint8List body) {
    final r = ByteReader(body);
    final protocol = r.u16();
    final state = r.u8();
    final caps = r.u8();
    final board = utf8.decode(r.short(), allowMalformed: true);
    final version = utf8.decode(r.short(), allowMalformed: true);
    return CatCardIdentity(
      protocolVersion: protocol,
      state: state,
      caps: caps,
      board: board,
      version: version,
    );
  }

  @override
  String toString() =>
      'CatCard $board $version (protocol $protocolVersion, '
      '${unlocked ? 'unlocked' : 'locked'}, caps 0x${caps.toRadixString(16)})';
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Anything that stops a CatCard exchange. [message] is for a person.
class CatCardException implements Exception {
  CatCardException(this.message);

  final String message;

  @override
  String toString() => 'CatCardException: $message';
}

/// The person at the device said no.
class CatCardDeclined extends CatCardException {
  CatCardDeclined([String? message]) : super(message ?? 'Declined on the device');
}

/// The device refused with a reason to show.
class CatCardRefused extends CatCardException {
  CatCardRefused(super.message);
}

/// Well formed, wrong time: locked, busy, nothing to fetch. [detail] is the
/// byte the device sent with it (a busy reason or a result stage).
class CatCardNotNow extends CatCardException {
  CatCardNotNow(super.message, {this.detail = 0});

  final int detail;
}

/// Bytes that are not what the protocol says they are.
class CatCardProtocolException extends CatCardException {
  CatCardProtocolException(super.message);
}

// ---------------------------------------------------------------------------
// Byte helpers
// ---------------------------------------------------------------------------

/// A little-endian cursor over a reply that refuses to run off the end.
class ByteReader {
  ByteReader(this.bytes);

  final Uint8List bytes;
  int at = 0;

  int get remaining => bytes.length - at;

  Uint8List take(int n) {
    if (n < 0 || at + n > bytes.length) {
      throw CatCardProtocolException('truncated reply');
    }
    final out = Uint8List.sublistView(bytes, at, at + n);
    at += n;
    return out;
  }

  int u8() => take(1)[0];

  int u16() {
    final b = take(2);
    return b[0] | (b[1] << 8);
  }

  int u32() {
    final b = take(4);
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
  }

  /// A `[u8 len][bytes]` field.
  Uint8List short() => take(u8());

  Uint8List rest() => take(remaining);

  /// Trailing bytes are a host and a device disagreeing about the layout.
  void done() {
    if (at != bytes.length) {
      throw CatCardProtocolException('trailing bytes in reply');
    }
  }
}

/// A little-endian builder.
class ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  int get length => _b.length;

  void u8(int v) => _b.addByte(v & 0xFF);

  void u16(int v) {
    _b.addByte(v & 0xFF);
    _b.addByte((v >> 8) & 0xFF);
  }

  void u32(int v) {
    _b.addByte(v & 0xFF);
    _b.addByte((v >> 8) & 0xFF);
    _b.addByte((v >> 16) & 0xFF);
    _b.addByte((v >> 24) & 0xFF);
  }

  void bytes(List<int> v) => _b.add(v);

  /// A `[u8 len][bytes]` field.
  void short(List<int> v) {
    if (v.length > 255) {
      throw ArgumentError('short field over 255 bytes');
    }
    u8(v.length);
    bytes(v);
  }

  Uint8List toBytes() => _b.toBytes();
}

Uint8List u32le(int v) => (ByteWriter()..u32(v)).toBytes();

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List bytesOfHex(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  if (clean.length.isOdd) throw ArgumentError('odd hex length');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
