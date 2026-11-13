import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/ledger/ledger_framing.dart';
import 'package:tibaneapp/services/ledger/ledger_transport.dart';

Uint8List _hex(String s) {
  final clean = s.replaceAll(' ', '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List _bytes(int n, [int seed = 0]) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i * 7 + seed) & 0xff]);

/// Device-side encoding of an answer: same framing as the host's.
List<Uint8List> _hidAnswer(Uint8List answer) => ledgerHidFrames(answer);
List<Uint8List> _bleAnswer(Uint8List answer, int mtu) =>
    ledgerBleFrames(answer, mtu);

void main() {
  group('HID framing', () {
    test('known vector: getAppAndVersion-style 5-byte APDU', () {
      final frames = ledgerHidFrames(_hex('e0 01 00 00 00'));
      expect(frames, hasLength(1));
      final expected = Uint8List(64)
        ..setRange(0, 12, _hex('01 01 05 00 00 00 05 e0 01 00 00 00'));
      expect(frames.single, expected);
    });

    test('every packet is 64 bytes with channel, tag and sequence', () {
      final frames = ledgerHidFrames(_bytes(300));
      // 302 bytes of payload stream in 59-byte blocks.
      expect(frames, hasLength(6));
      for (var i = 0; i < frames.length; i++) {
        final f = frames[i];
        expect(f.length, 64);
        expect(f.sublist(0, 3), [0x01, 0x01, 0x05]);
        expect((f[3] << 8) | f[4], i);
      }
      // Length in the first packet, big-endian.
      expect(frames[0].sublist(5, 7), [0x01, 0x2c]);
    });

    test('block boundaries: 57 bytes fit one packet, 58 need two', () {
      expect(ledgerHidFrames(_bytes(57)), hasLength(1));
      expect(ledgerHidFrames(_bytes(58)), hasLength(2));
      expect(ledgerHidFrames(_bytes(57 + 59)), hasLength(2));
      expect(ledgerHidFrames(_bytes(57 + 59 + 1)), hasLength(3));
    });

    for (final n in [2, 5, 57, 58, 116, 117, 255, 260, 1000, 4096]) {
      test('round trip $n bytes', () {
        final apdu = _bytes(n, n);
        expect(ledgerHidReassemble(ledgerHidFrames(apdu)), apdu);
      });
    }

    test('reassembles a device answer (9000) and ignores padding', () {
      final answer = _hex('01 02 03 90 00');
      final r = LedgerHidReassembler();
      final out = r.add(_hidAnswer(answer).single);
      expect(out, answer);
      expect(r.isComplete, isTrue);
    });

    test('multi-packet answer returns null until complete', () {
      final answer = _bytes(150, 3);
      final packets = _hidAnswer(answer);
      expect(packets, hasLength(3));
      final r = LedgerHidReassembler();
      expect(r.add(packets[0]), isNull);
      expect(r.add(packets[1]), isNull);
      expect(r.add(packets[2]), answer);
    });

    test('rejects wrong channel, tag and sequence', () {
      final packets = _hidAnswer(_bytes(150));
      final badChannel = Uint8List.fromList(packets[0])..[1] = 0x02;
      expect(
        () => LedgerHidReassembler().add(badChannel),
        throwsA(isA<LedgerFramingException>()),
      );
      final badTag = Uint8List.fromList(packets[0])..[2] = 0x06;
      expect(
        () => LedgerHidReassembler().add(badTag),
        throwsA(isA<LedgerFramingException>()),
      );
      final r = LedgerHidReassembler()..add(packets[0]);
      expect(() => r.add(packets[2]), throwsA(isA<LedgerFramingException>()));
    });

    test('incomplete answer throws', () {
      final packets = _hidAnswer(_bytes(150));
      expect(
        () => ledgerHidReassemble(packets.take(2)),
        throwsA(isA<LedgerFramingException>()),
      );
    });
  });

  group('BLE framing', () {
    test('known vector at the default MTU', () {
      final frames = ledgerBleFrames(
        _hex('e0 01 00 00 00'),
        ledgerBleDefaultMtu,
      );
      expect(frames.single, _hex('05 00 00 00 05 e0 01 00 00 00'));
    });

    test('frames are sized by MTU: 5-byte head first, 3-byte head after', () {
      final apdu = _bytes(100);
      final frames = ledgerBleFrames(apdu, 20);
      // 15 bytes in the first frame, 17 in each next one: 15 + 17*5 = 100.
      expect(frames, hasLength(6));
      expect(frames[0].length, 20);
      expect(frames[0].sublist(0, 5), [0x05, 0x00, 0x00, 0x00, 100]);
      expect(frames[1].sublist(0, 3), [0x05, 0x00, 0x01]);
      expect(frames.last.length, 3 + 17);
      for (final f in frames) {
        expect(f.length, lessThanOrEqualTo(20));
      }
    });

    test('last frame is not padded', () {
      final frames = ledgerBleFrames(_bytes(16), 20);
      expect(frames, hasLength(2));
      expect(frames[1], [0x05, 0x00, 0x01, (15 * 7) & 0xff]);
    });

    test('empty APDU still sends a header frame', () {
      expect(ledgerBleFrames(Uint8List(0), 20).single, [0x05, 0, 0, 0, 0]);
    });

    for (final mtu in [20, 23, 128, 153, 244, 509]) {
      for (final n in [2, 5, 15, 16, 255, 1000, 4096]) {
        test('round trip $n bytes at MTU $mtu', () {
          final apdu = _bytes(n, mtu);
          final frames = ledgerBleFrames(apdu, mtu);
          for (final f in frames) {
            expect(f.length, lessThanOrEqualTo(mtu));
          }
          expect(ledgerBleReassemble(frames), apdu);
        });
      }
    }

    test('multi-frame answer returns null until complete', () {
      final answer = _bytes(40, 9);
      final frames = _bleAnswer(answer, 20);
      expect(frames, hasLength(3));
      final r = LedgerBleReassembler();
      expect(r.add(frames[0]), isNull);
      expect(r.add(frames[1]), isNull);
      expect(r.add(frames[2]), answer);
      expect(r.isComplete, isTrue);
    });

    test('rejects wrong tag and sequence', () {
      final frames = _bleAnswer(_bytes(40), 20);
      expect(
        () => LedgerBleReassembler().add(_hex('08 00 00 00 00 99')),
        throwsA(isA<LedgerFramingException>()),
      );
      final r = LedgerBleReassembler()..add(frames[0]);
      expect(() => r.add(frames[2]), throwsA(isA<LedgerFramingException>()));
    });

    test('MTU request and answer', () {
      expect(ledgerBleMtuRequest(), [0x08, 0, 0, 0, 0]);
      expect(ledgerBleParseMtu(_hex('08 00 00 00 00 99')), 0x99);
      expect(ledgerBleParseMtu(_hex('05 00 00 00 02 90 00')), isNull);
      expect(ledgerBleParseMtu(_hex('08 00 00')), isNull);
    });

    test('rejects an MTU too small to carry the header', () {
      expect(
        () => ledgerBleFrames(_bytes(5), 5),
        throwsA(isA<LedgerFramingException>()),
      );
    });
  });

  group('LedgerSerialLock', () {
    test('runs tasks one at a time in order, surviving failures', () async {
      final lock = LedgerSerialLock();
      final log = <String>[];
      var inFlight = 0;
      Future<int> task(int i, {bool fail = false}) => lock.run(() async {
        inFlight++;
        expect(inFlight, 1);
        log.add('start $i');
        await Future<void>.delayed(Duration(milliseconds: 5 - i));
        log.add('end $i');
        inFlight--;
        if (fail) throw StateError('boom $i');
        return i;
      });
      final a = task(0);
      final b = task(1, fail: true);
      final c = task(2);
      expect(await a, 0);
      await expectLater(b, throwsStateError);
      expect(await c, 2);
      expect(log, ['start 0', 'end 0', 'start 1', 'end 1', 'start 2', 'end 2']);
    });
  });

  test('LedgerException carries a stable code in toString', () {
    const e = LedgerException(LedgerException.bluetoothOff, 'off');
    expect(e.toString(), contains('BLUETOOTH_OFF'));
    expect(
      asLedgerException(TimeoutException('t')).code,
      LedgerException.timeout,
    );
  });
}
