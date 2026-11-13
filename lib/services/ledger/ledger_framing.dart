import 'dart:typed_data';

/// Ledger's APDU framing for USB HID and Bluetooth LE, as in
/// `@ledgerhq/devices` (`hid-framing` and `ble/sendAPDU` / `ble/receiveAPDU`).
///
/// Both cut an APDU into frames that start with tag 0x05 and a big-endian
/// 16-bit sequence index, the first frame also carrying the APDU length
/// (big-endian u16). HID adds a 16-bit channel in front and pads every packet
/// to 64 bytes; BLE frames are sized by the negotiated MTU and not padded.
/// The answer (data plus the 2-byte status word) comes back framed the same
/// way.
///
/// The Android USB bridge (`LedgerUsb.kt`) does the HID variant natively; this
/// one is the tested reference and what the BLE transport uses.

/// The tag of an APDU frame.
const int ledgerApduTag = 0x05;

/// The tag of the BLE "get MTU" request and its answer.
const int ledgerBleMtuTag = 0x08;

/// The HID channel Ledger devices answer on.
const int ledgerHidChannel = 0x0101;

/// HID report size.
const int ledgerHidPacketSize = 64;

/// BLE frame size before the device has told us its MTU (ATT MTU 23 - 3).
const int ledgerBleDefaultMtu = 20;

/// The BLE frame asking the device for its MTU; it answers
/// `08 00 00 00 00 <mtu>` on the notify characteristic.
Uint8List ledgerBleMtuRequest() => Uint8List.fromList(const [0x08, 0, 0, 0, 0]);

/// A malformed frame, or one that does not belong to the answer being read.
class LedgerFramingException implements Exception {
  final String message;
  const LedgerFramingException(this.message);
  @override
  String toString() => 'LedgerFramingException: $message';
}

void _u16(Uint8List b, int at, int v) {
  b[at] = (v >> 8) & 0xff;
  b[at + 1] = v & 0xff;
}

int _readU16(Uint8List b, int at) => (b[at] << 8) | b[at + 1];

// ---- HID ----------------------------------------------------------------------

/// The 64-byte HID packets carrying [apdu]: `channel | 0x05 | seq | payload`,
/// where the payload stream is `len (u16) | apdu`, zero-padded.
List<Uint8List> ledgerHidFrames(
  Uint8List apdu, {
  int channel = ledgerHidChannel,
  int packetSize = ledgerHidPacketSize,
}) {
  if (apdu.length > 0xffff) {
    throw const LedgerFramingException('APDU longer than 65535 bytes');
  }
  final data = Uint8List(2 + apdu.length);
  _u16(data, 0, apdu.length);
  data.setRange(2, data.length, apdu);
  final block = packetSize - 5;
  final frames = <Uint8List>[];
  for (var offset = 0, seq = 0; offset < data.length; offset += block, seq++) {
    final packet = Uint8List(packetSize);
    _u16(packet, 0, channel);
    packet[2] = ledgerApduTag;
    _u16(packet, 3, seq);
    final end = offset + block < data.length ? offset + block : data.length;
    packet.setRange(5, 5 + end - offset, data, offset);
    frames.add(packet);
  }
  return frames;
}

/// Rebuilds an answer from HID packets. Feed packets in order to [add]; it
/// returns the whole answer once the declared length has arrived, null before.
class LedgerHidReassembler {
  final int channel;
  final BytesBuilder _data = BytesBuilder(copy: false);
  int _expected = -1;
  int _seq = 0;
  Uint8List? _result;

  LedgerHidReassembler({this.channel = ledgerHidChannel});

  bool get isComplete => _result != null;

  Uint8List? add(Uint8List packet) {
    if (_result != null) {
      throw const LedgerFramingException('answer already complete');
    }
    if (packet.length < 5) {
      throw const LedgerFramingException('packet too short');
    }
    if (_readU16(packet, 0) != channel) {
      throw const LedgerFramingException('invalid channel');
    }
    if (packet[2] != ledgerApduTag) {
      throw const LedgerFramingException('invalid tag');
    }
    if (_readU16(packet, 3) != _seq) {
      throw const LedgerFramingException('invalid sequence');
    }
    var start = 5;
    if (_seq == 0) {
      if (packet.length < 7) {
        throw const LedgerFramingException('packet too short');
      }
      _expected = _readU16(packet, 5);
      start = 7;
    }
    _seq++;
    return _append(packet, start);
  }

  Uint8List? _append(Uint8List packet, int start) {
    final want = _expected - _data.length;
    final have = packet.length - start;
    _data.add(
      Uint8List.sublistView(packet, start, start + (have < want ? have : want)),
    );
    if (_data.length >= _expected) return _result = _data.takeBytes();
    return null;
  }
}

/// Reads one whole HID answer from [packets].
Uint8List ledgerHidReassemble(
  Iterable<Uint8List> packets, {
  int channel = ledgerHidChannel,
}) {
  final r = LedgerHidReassembler(channel: channel);
  for (final p in packets) {
    final out = r.add(p);
    if (out != null) return out;
  }
  throw const LedgerFramingException('answer incomplete');
}

// ---- BLE ----------------------------------------------------------------------

/// The BLE frames carrying [apdu] for a device MTU of [mtu] bytes per frame:
/// the first `0x05 | 0x0000 | len (u16) | data`, then `0x05 | seq | data`.
List<Uint8List> ledgerBleFrames(Uint8List apdu, int mtu) {
  if (apdu.length > 0xffff) {
    throw const LedgerFramingException('APDU longer than 65535 bytes');
  }
  if (mtu < 6) throw LedgerFramingException('MTU $mtu too small');
  final frames = <Uint8List>[];
  var offset = 0;
  var seq = 0;
  do {
    final head = seq == 0 ? 5 : 3;
    final room = mtu - head;
    final n = apdu.length - offset < room ? apdu.length - offset : room;
    final frame = Uint8List(head + n);
    frame[0] = ledgerApduTag;
    _u16(frame, 1, seq);
    if (seq == 0) _u16(frame, 3, apdu.length);
    frame.setRange(head, head + n, apdu, offset);
    frames.add(frame);
    offset += n;
    seq++;
  } while (offset < apdu.length);
  return frames;
}

/// Rebuilds an answer from BLE notifications, like [LedgerHidReassembler].
class LedgerBleReassembler {
  final BytesBuilder _data = BytesBuilder(copy: false);
  int _expected = -1;
  int _seq = 0;
  Uint8List? _result;

  bool get isComplete => _result != null;

  Uint8List? add(Uint8List frame) {
    if (_result != null) {
      throw const LedgerFramingException('answer already complete');
    }
    if (frame.length < 3) throw const LedgerFramingException('frame too short');
    if (frame[0] != ledgerApduTag) {
      throw LedgerFramingException(
        'invalid tag 0x${frame[0].toRadixString(16)}',
      );
    }
    if (_readU16(frame, 1) != _seq) {
      throw const LedgerFramingException('invalid sequence');
    }
    var start = 3;
    if (_seq == 0) {
      if (frame.length < 5) {
        throw const LedgerFramingException('frame too short');
      }
      _expected = _readU16(frame, 3);
      start = 5;
    }
    _seq++;
    final want = _expected - _data.length;
    final have = frame.length - start;
    _data.add(
      Uint8List.sublistView(frame, start, start + (have < want ? have : want)),
    );
    if (_data.length >= _expected) return _result = _data.takeBytes();
    return null;
  }
}

/// Reads one whole BLE answer from [frames].
Uint8List ledgerBleReassemble(Iterable<Uint8List> frames) {
  final r = LedgerBleReassembler();
  for (final f in frames) {
    final out = r.add(f);
    if (out != null) return out;
  }
  throw const LedgerFramingException('answer incomplete');
}

/// The MTU in a device's answer to [ledgerBleMtuRequest], or null when
/// [frame] is not that answer.
int? ledgerBleParseMtu(Uint8List frame) {
  if (frame.length < 6 || frame[0] != ledgerBleMtuTag) return null;
  return frame[5];
}
