import 'dart:typed_data';

import 'transport.dart';
import 'wire.dart';

/// CatCard messages as APDUs to the card in its CCID smart-card reader
/// (docs/PHONE-APP.md §2; `catcard_usb::ccid::apdu`; reference
/// `tools/ccidclient.py`).
///
/// ```text
/// CLA   80  a whole message, or the last chunk of one
///       90  a chunk with more to follow
/// INS   CC
/// P1 P2 00 00
/// data  first chunk: [u16 opcode][u32 total][payload]; later chunks: [payload]
/// Le    always sent: 00 (256) short, 00 00 (65536) extended
/// ```
///
/// The reply data is `[u16 status][u32 total][payload]` with SW `90 00`; a
/// reply longer than `Le` comes back paged with `61 xx` and `GET RESPONSE`.

const int apduCla = 0x80;
const int apduClaChain = 0x10;
const int apduInsMessage = 0xCC;
const int apduInsGetResponse = 0xC0;

/// `[u16 opcode][u32 total]` in, `[u16 status][u32 total]` out.
const int apduMessageHeader = 6;

/// Data bytes per chunk: the reader's `APDU_MAX` (1078) less the extended
/// header (7), our six-byte message header and a two-byte Le, rounded down.
const int apduChunkExtended = 1024;

/// A short APDU's data field, less the message header.
const int apduChunkShort = 255 - apduMessageHeader;

const int swOk = 0x9000;
const int swMoreMask = 0xFF00;
const int swMore = 0x6100;

/// A smart card that takes one APDU and answers with data and a status word.
abstract class ApduCard {
  Future<ApduResponse> transmit(Uint8List apdu);

  Future<void> close();
}

class ApduResponse {
  const ApduResponse(this.data, this.sw);

  final Uint8List data;
  final int sw;

  /// Split a raw response whose last two bytes are the status word.
  factory ApduResponse.fromRaw(Uint8List raw) {
    if (raw.length < 2) {
      throw CatCardProtocolException('APDU response shorter than a status word');
    }
    final sw = (raw[raw.length - 2] << 8) | raw[raw.length - 1];
    return ApduResponse(Uint8List.sublistView(raw, 0, raw.length - 2), sw);
  }
}

/// Case 2/4 short, or case 2E/4E extended, with `Le` = the maximum.
Uint8List encodeApdu(
  int cla,
  int ins,
  int p1,
  int p2,
  List<int> data, {
  bool short = false,
}) {
  final b = BytesBuilder(copy: false)
    ..addByte(cla)
    ..addByte(ins)
    ..addByte(p1)
    ..addByte(p2);
  if (short) {
    if (data.length > 255) {
      throw ArgumentError('short APDU data over 255 bytes');
    }
    if (data.isNotEmpty) {
      b
        ..addByte(data.length)
        ..add(data);
    }
    b.addByte(0x00);
    return b.toBytes();
  }
  if (data.isNotEmpty) {
    b
      ..addByte(0x00)
      ..addByte((data.length >> 8) & 0xFF)
      ..addByte(data.length & 0xFF)
      ..add(data)
      ..addByte(0x00)
      ..addByte(0x00);
  } else {
    b
      ..addByte(0x00)
      ..addByte(0x00)
      ..addByte(0x00);
  }
  return b.toBytes();
}

/// The APDUs that carry one message: a header on the first, chaining on all
/// but the last, an `Le` on every one.
List<Uint8List> messageApdus(
  int opcode,
  List<int> payload, {
  bool short = false,
}) {
  final data = (ByteWriter()
        ..u16(opcode)
        ..u32(payload.length)
        ..bytes(payload))
      .toBytes();
  final chunk = (short ? apduChunkShort : apduChunkExtended) + apduMessageHeader;
  final pieces = <Uint8List>[];
  for (var at = 0; at < data.length; at += chunk) {
    final end = at + chunk < data.length ? at + chunk : data.length;
    pieces.add(Uint8List.sublistView(data, at, end));
  }
  if (pieces.isEmpty) pieces.add(data);
  final out = <Uint8List>[];
  for (var i = 0; i < pieces.length; i++) {
    final last = i == pieces.length - 1;
    final cla = last ? apduCla : apduCla | apduClaChain;
    out.add(encodeApdu(cla, apduInsMessage, 0, 0, pieces[i], short: short));
  }
  return out;
}

Uint8List getResponseApdu({bool short = false}) =>
    encodeApdu(0x00, apduInsGetResponse, 0, 0, const [], short: short);

/// A [CatCardTransport] over an [ApduCard]: one message per exchange, chained
/// when it is long, paged back when the reply is.
class ApduTransport implements CatCardTransport {
  ApduTransport(this.card, {this.short = false});

  final ApduCard card;

  /// Short APDUs only: chunks of 255, replies paged by `GET RESPONSE`.
  final bool short;

  @override
  Future<Reply> request(int opcode, [Uint8List? payload]) async {
    final body = BytesBuilder(copy: false);
    var sw = swOk;
    for (final apdu in messageApdus(opcode, payload ?? Uint8List(0), short: short)) {
      final r = await card.transmit(apdu);
      body.add(r.data);
      sw = r.sw;
    }
    while ((sw & swMoreMask) == swMore) {
      final r = await card.transmit(getResponseApdu(short: short));
      body.add(r.data);
      sw = r.sw;
    }
    if (sw != swOk) {
      throw CatCardProtocolException(
        'card refused the APDU: SW ${sw.toRadixString(16).padLeft(4, '0')}',
      );
    }
    final bytes = body.toBytes();
    if (bytes.length < apduMessageHeader) {
      throw CatCardProtocolException('reply too short for a message header');
    }
    final r = ByteReader(bytes);
    final status = r.u16();
    final total = r.u32();
    final rest = r.rest();
    if (rest.length != total) {
      throw CatCardProtocolException(
        'reply says $total bytes, carried ${rest.length}',
      );
    }
    return Reply(status, rest);
  }

  @override
  Future<void> close() => card.close();
}
