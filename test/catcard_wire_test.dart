import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/catcard/apdu.dart';
import 'package:tibaneapp/services/catcard/wire.dart';

/// The bytes on the wire, pinned to `tools/ccidclient.py --selftest` and the
/// worked example in docs/PHONE-APP.md.
void main() {
  group('Identify', () {
    test('parses the doc example: an unlocked Q1 running 7.0.0', () {
      final id = CatCardIdentity.parse(
        bytesOfHex('02 00 01 C0 02 71 31 05 37 2E 30 2E 30'),
      );
      expect(id.protocolVersion, 2);
      expect(id.unlocked, isTrue);
      expect(id.blank, isFalse);
      expect(id.caps, 0xC0);
      expect(id.hasPairing, isTrue);
      expect(id.hasHostWallet, isTrue);
      expect(id.isBench, isFalse);
      expect(id.usable, isTrue);
      expect(id.board, 'q1');
      expect(id.version, '7.0.0');
    });

    test('a bench build is flagged', () {
      final id = CatCardIdentity.parse(
        bytesOfHex('02 00 01 C5 03 6D 6B 34 05 37 2E 30 2E 30'),
      );
      expect(id.isBench, isTrue);
      expect(id.board, 'mk4');
    });

    test('a truncated body is refused', () {
      expect(
        () => CatCardIdentity.parse(bytesOfHex('02 00 01 C0 05 71')),
        throwsA(isA<CatCardProtocolException>()),
      );
    });
  });

  group('APDU encoding', () {
    test('one short message, extended: Identify', () {
      final a = messageApdus(Opcode.identify, const []);
      expect(a, hasLength(1));
      expect(hexOf(a[0]), '80cc0000000006' '0200' '00000000' '0000');
    });

    test('short: Ping "hi"', () {
      final a = messageApdus(Opcode.ping, 'hi'.codeUnits, short: true);
      expect(hexOf(a[0]), '80cc000008' '0100' '02000000' '6869' '00');
    });

    test('chained, short: 249 payload bytes per chunk after the header', () {
      final payload = Uint8List.fromList([
        for (var i = 0; i < 512; i++) i & 0xFF,
      ]);
      final a = messageApdus(0x0041, payload, short: true);
      expect(a, hasLength(3));
      expect(a[0][0], 0x90);
      expect(a[1][0], 0x90);
      expect(a[2][0], 0x80);
      expect(a[0][4], 255);
      expect(hexOf(a[0].sublist(5, 11)), '4100' '00020000');
      final joined = Uint8List.fromList([
        for (final x in a) ...x.sublist(5, x.length - 1),
      ]);
      expect(hexOf(joined.sublist(0, 6)), '4100' '00020000');
      expect(joined.sublist(6), payload);
    });

    test('chained, extended: 1030 bytes on the first, the rest on the second', () {
      final a = messageApdus(0x0041, Uint8List(1500));
      expect(a, hasLength(2));
      expect(a[0][0], 0x90);
      expect(a[1][0], 0x80);
      expect((a[0][5] << 8) | a[0][6], 1030);
      expect((a[1][5] << 8) | a[1][6], 476);
    });

    test('GET RESPONSE', () {
      expect(hexOf(getResponseApdu()), '00c00000000000');
      expect(hexOf(getResponseApdu(short: true)), '00c0000000');
    });
  });

  group('ApduTransport', () {
    test('pages a 300-byte body by 255 in short mode', () async {
      final card = _PagingCard();
      final t = ApduTransport(card, short: true);
      final r = await t.request(Opcode.identify);
      expect(r.status, Status.ok);
      expect(r.body, Uint8List(300));
      expect(card.seen, hasLength(2));
      expect(card.seen[1][1], apduInsGetResponse);
    });

    test('a status word other than 9000 is an error', () async {
      final t = ApduTransport(_RefusingCard());
      expect(
        () => t.request(Opcode.identify),
        throwsA(isA<CatCardProtocolException>()),
      );
    });

    test('a reply whose total disagrees with its length is refused', () async {
      final t = ApduTransport(_LyingCard());
      expect(
        () => t.request(Opcode.identify),
        throwsA(isA<CatCardProtocolException>()),
      );
    });
  });
}

/// A card that answers Identify-like bodies 300 bytes long, paged by 255.
class _PagingCard implements ApduCard {
  Uint8List pending = Uint8List(0);
  final List<Uint8List> seen = [];

  @override
  Future<ApduResponse> transmit(Uint8List apdu) async {
    seen.add(apdu);
    if (apdu[1] == apduInsGetResponse) {
      final page = pending.sublist(0, pending.length < 255 ? pending.length : 255);
      pending = pending.sublist(page.length);
      final sw = pending.isEmpty
          ? swOk
          : swMore | (pending.length < 255 ? pending.length : 255);
      return ApduResponse(page, sw);
    }
    if (apdu[0] & apduClaChain != 0) return ApduResponse(Uint8List(0), swOk);
    final body = (ByteWriter()
          ..u16(0)
          ..u32(300)
          ..bytes(Uint8List(300)))
        .toBytes();
    final page = body.sublist(0, 255);
    pending = body.sublist(255);
    return ApduResponse(page, swMore | (pending.length < 255 ? pending.length : 255));
  }

  @override
  Future<void> close() async {}
}

class _RefusingCard implements ApduCard {
  @override
  Future<ApduResponse> transmit(Uint8List apdu) async =>
      ApduResponse(Uint8List(0), 0x6D00);

  @override
  Future<void> close() async {}
}

class _LyingCard implements ApduCard {
  @override
  Future<ApduResponse> transmit(Uint8List apdu) async => ApduResponse(
    (ByteWriter()
          ..u16(0)
          ..u32(9)
          ..bytes([1, 2, 3]))
        .toBytes(),
    swOk,
  );

  @override
  Future<void> close() async {}
}
