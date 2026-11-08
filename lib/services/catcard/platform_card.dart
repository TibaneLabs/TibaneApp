import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'apdu.dart';
import 'wire.dart';

/// The CatCard's CCID smart-card reader as the platform exposes it:
/// CryptoTokenKit on iOS (`ios/Runner/CatCardChannel.swift`), the USB host
/// API driving the CCID interface directly on Android
/// (`android/.../CatCardUsb.kt`). Both speak the same small channel.
///
/// Method channel `net.tibane.tibaneapp/catcard`:
/// - `isSupported` → bool
/// - `listReaders` → the CatCard readers present, by name
/// - `open` {name?} → {name, atr}; powers the card on
/// - `transmit` {apdu} → response bytes, status word last
/// - `close`
///
/// Event channel `net.tibane.tibaneapp/catcard/readers`: the reader list,
/// again whenever a device is plugged in or pulled.
const MethodChannel _channel = MethodChannel('net.tibane.tibaneapp/catcard');
const EventChannel _readers = EventChannel(
  'net.tibane.tibaneapp/catcard/readers',
);

/// Which CatCards are plugged in.
abstract final class CatCardReaders {
  static Future<bool> get supported async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<List<String>> list() async {
    try {
      return await _channel.invokeListMethod<String>('listReaders') ??
          const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// The reader list, first on listen and then on every plug or pull.
  static Stream<List<String>> get changes => _readers
      .receiveBroadcastStream()
      .map((e) => (e as List).cast<String>());
}

/// A CatCard opened through the platform's reader.
class PlatformApduCard implements ApduCard {
  PlatformApduCard._(this.name, this.atr);

  final String name;
  final Uint8List atr;

  /// Open the named reader, or the first CatCard present. Asks the USB
  /// permission on Android when needed.
  static Future<PlatformApduCard> open({String? name}) async {
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('open', {
        'name': name,
      });
      if (r == null) throw CatCardException('The CatCard could not be opened.');
      return PlatformApduCard._(
        r['name'] as String,
        (r['atr'] as Uint8List?) ?? Uint8List(0),
      );
    } on PlatformException catch (e) {
      throw _translate(e);
    } on MissingPluginException {
      throw CatCardException('CatCard over USB is not available on this platform.');
    }
  }

  @override
  Future<ApduResponse> transmit(Uint8List apdu) async {
    try {
      final raw = await _channel.invokeMethod<Uint8List>('transmit', {
        'apdu': apdu,
      });
      if (raw == null) throw CatCardException('The CatCard did not answer.');
      return ApduResponse.fromRaw(raw);
    } on PlatformException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } on PlatformException catch (e) {
      debugPrint('catcard close: ${e.code} ${e.message}');
    }
  }

  static CatCardException _translate(PlatformException e) {
    final message = e.message ?? e.code;
    return switch (e.code) {
      'NO_DEVICE' => CatCardException('No CatCard is plugged in.'),
      'PERMISSION_DENIED' => CatCardException(
        'USB access to the CatCard was not allowed.',
      ),
      'UNSUPPORTED' => CatCardException(
        'This phone cannot talk to a smart-card reader over USB.',
      ),
      _ => CatCardException(message),
    };
  }
}
