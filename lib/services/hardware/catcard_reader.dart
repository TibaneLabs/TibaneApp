import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The CatCard's CCID smart-card reader as the platform exposes it:
/// CryptoTokenKit on iOS (`ios/Runner/CatCardChannel.swift`), the USB host
/// API driving the CCID interface directly on Android
/// (`android/.../CatCardUsb.kt`). libwallet speaks the CatCard protocol; the
/// app only carries its APDUs (`client.catcard.ccidBridge`).
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

/// A CatCard reader failure, by code: `NO_DEVICE`, `PERMISSION_DENIED`,
/// `UNSUPPORTED`, or the platform's own code.
class CatCardReaderException implements Exception {
  const CatCardReaderException(this.code, [this.message]);

  final String code;
  final String? message;

  @override
  String toString() => 'CatCard: ${message ?? code}';
}

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
      return await _channel.invokeListMethod<String>('listReaders') ?? const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// The reader list, first on listen and then on every plug or pull.
  static Stream<List<String>> get changes =>
      _readers.receiveBroadcastStream().map((e) => (e as List).cast<String>());
}

/// One open session with the card in a CatCard's reader. libwallet drives the
/// protocol through [transmit]; it does the chaining and `GET RESPONSE`
/// paging, so APDUs go through untouched.
class CatCardReader {
  bool _open = false;
  Future<void>? _opening;

  bool get isOpen => _open;

  Future<void> _ensureOpen() {
    if (_open) return Future.value();
    return _opening ??= _openNow().whenComplete(() => _opening = null);
  }

  Future<void> _openNow() async {
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('open', {
        'name': null,
      });
      if (r == null) throw const CatCardReaderException('NO_DEVICE');
      _open = true;
    } on PlatformException catch (e) {
      throw CatCardReaderException(e.code, e.message);
    } on MissingPluginException {
      throw const CatCardReaderException('UNSUPPORTED');
    }
  }

  /// Send one command APDU and return the response, status word included.
  /// A failed exchange closes the session so the next one reopens the card
  /// (after an unplug, a fresh power-on).
  Future<Uint8List> transmit(Uint8List apdu) async {
    await _ensureOpen();
    try {
      final raw = await _channel.invokeMethod<Uint8List>('transmit', {
        'apdu': apdu,
      });
      if (raw == null) throw const CatCardReaderException('NO_DEVICE');
      return raw;
    } on PlatformException catch (e) {
      await close();
      throw CatCardReaderException(e.code, e.message);
    }
  }

  Future<void> close() async {
    if (!_open) return;
    _open = false;
    try {
      await _channel.invokeMethod<void>('close');
    } on PlatformException catch (e) {
      debugPrint('catcard close: ${e.code} ${e.message}');
    }
  }
}
