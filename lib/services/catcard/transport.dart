import 'dart:typed_data';

import 'wire.dart';

/// One way of getting a CatCard wire message to a device and its reply back:
/// an APDU through the CCID reader (phones), or HID frames (a computer). The
/// protocol above this -- pairing, host-wallet -- never sees which.
abstract class CatCardTransport {
  /// Send one message and return its reply. Throws [CatCardException] when
  /// the transport itself fails (unplugged, the card refused the APDU); a
  /// message-level status such as `NotNow` is returned, not thrown.
  Future<Reply> request(int opcode, [Uint8List? payload]);

  /// Release the device.
  Future<void> close();
}
