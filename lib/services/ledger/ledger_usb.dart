import 'dart:async';

import 'package:flutter/services.dart';

import 'ledger_transport.dart';

/// The Android USB-OTG bridge (`LedgerUsb.kt`): it finds the Ledger's HID
/// interface and does the HID framing; this side only passes APDUs.
class LedgerUsb {
  LedgerUsb._();

  static const MethodChannel channel = MethodChannel(
    'net.tibane.tibaneapp/ledger',
  );

  static Future<bool> isSupported() async {
    try {
      return await channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<List<LedgerDeviceInfo>> list() async {
    try {
      final raw = await channel.invokeListMethod<Object?>('list') ?? const [];
      return [
        for (final d in raw.whereType<Map<Object?, Object?>>())
          LedgerDeviceInfo(
            id: d['id'] as String,
            name: (d['name'] as String?) ?? 'Ledger',
            kind: 'usb',
          ),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (e) {
      throw mapUsbError(e);
    }
  }

  static LedgerException mapUsbError(PlatformException e) {
    final code = switch (e.code) {
      'NO_DEVICE' => LedgerException.noDevice,
      'PERMISSION_DENIED' => LedgerException.permissionDenied,
      'UNSUPPORTED' => LedgerException.unsupported,
      'DISCONNECTED' => LedgerException.disconnected,
      'TIMEOUT' => LedgerException.timeout,
      _ => LedgerException.io,
    };
    return LedgerException(code, e.message ?? e.code);
  }
}

/// A Ledger over USB-OTG on Android.
///
/// Opening an app on the device (or quitting one) can make it drop off the
/// bus and come back as a new USB device. The transport then reports
/// `disconnected`; the next [exchange] waits a few seconds for a Ledger to
/// reappear and reopens it (with the vendor in `device_filter.xml` and "always
/// open" ticked, Android grants it again without asking). An APDU that failed
/// before any byte of it was written is resent after such a reopen.
class LedgerUsbTransport implements LedgerTransport {
  LedgerUsbTransport._(this._info, this._onStatus);

  static const _reappearWait = Duration(seconds: 10);
  static const _pollEvery = Duration(milliseconds: 300);

  LedgerDeviceInfo _info;
  final LedgerStatusCallback? _onStatus;
  final LedgerSerialLock _lock = LedgerSerialLock();
  bool _open = false;
  bool _closed = false;

  static Future<LedgerUsbTransport> open(
    LedgerDeviceInfo info, {
    LedgerStatusCallback? onStatus,
  }) async {
    final t = LedgerUsbTransport._(info, onStatus);
    await t._openNative(info.id);
    return t;
  }

  Future<void> _openNative(String? id) async {
    try {
      final r = await LedgerUsb.channel.invokeMapMethod<String, Object?>(
        'open',
        {'id': id},
      );
      if (r != null && r['id'] is String) {
        _info = LedgerDeviceInfo(
          id: r['id'] as String,
          name: (r['name'] as String?) ?? _info.name,
          kind: 'usb',
        );
      }
      _open = true;
    } on PlatformException catch (e) {
      throw LedgerUsb.mapUsbError(e);
    } on MissingPluginException {
      throw const LedgerException(
        LedgerException.unsupported,
        'No USB bridge in this build.',
      );
    }
  }

  @override
  String get name => _info.name;

  @override
  String get kind => 'usb';

  @override
  bool get isOpen => _open && !_closed;

  @override
  Future<Uint8List> exchange(Uint8List apdu) => _lock.run(() async {
    if (_closed) {
      throw const LedgerException(
        LedgerException.disconnected,
        'The Ledger link is closed.',
      );
    }
    if (!_open) await _reconnect();
    try {
      return await _send(apdu);
    } on LedgerException catch (e) {
      if (e.code != LedgerException.disconnected || _closed) rethrow;
      _lost(e.code);
      if (!e.unsent) rethrow;
      await _reconnect();
      return _send(apdu);
    }
  });

  Future<Uint8List> _send(Uint8List apdu) async {
    try {
      final r = await LedgerUsb.channel.invokeMethod<Uint8List>('exchange', {
        'apdu': apdu,
      });
      if (r == null) {
        throw const LedgerException(LedgerException.io, 'Empty answer.');
      }
      if (r.length < 2) {
        throw const LedgerException(
          LedgerException.io,
          'Answer has no status word.',
        );
      }
      return r;
    } on PlatformException catch (e) {
      final err = LedgerUsb.mapUsbError(e);
      throw e.details == 'unsent' ? err.markUnsent() : err;
    }
  }

  void _lost(String code) {
    _open = false;
    if (!_closed) _onStatus?.call(LedgerConnectionStatus.disconnected, code);
  }

  /// Wait for a Ledger to show up on the bus again and open it.
  Future<void> _reconnect() async {
    _onStatus?.call(LedgerConnectionStatus.connecting, null);
    final deadline = DateTime.now().add(_reappearWait);
    while (true) {
      final found = await LedgerUsb.list();
      if (_closed) {
        throw const LedgerException(
          LedgerException.disconnected,
          'The Ledger link is closed.',
        );
      }
      if (found.isNotEmpty) {
        // Same path if it is still there, else the (only) Ledger that came back.
        final target = found.firstWhere(
          (d) => d.id == _info.id,
          orElse: () => found.first,
        );
        try {
          await _openNative(target.id);
          _onStatus?.call(LedgerConnectionStatus.connected, null);
          return;
        } on LedgerException catch (e) {
          if (e.code == LedgerException.permissionDenied ||
              DateTime.now().isAfter(deadline)) {
            _onStatus?.call(LedgerConnectionStatus.disconnected, e.code);
            rethrow;
          }
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        _onStatus?.call(
          LedgerConnectionStatus.disconnected,
          LedgerException.disconnected,
        );
        throw const LedgerException(
          LedgerException.disconnected,
          'The Ledger did not come back on USB.',
        );
      }
      await Future<void>.delayed(_pollEvery);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _open = false;
    try {
      await LedgerUsb.channel.invokeMethod<void>('close');
    } on PlatformException {
      // already gone
    } on MissingPluginException {
      // no bridge
    }
  }
}

extension on LedgerException {
  /// Tag a failure that happened before the APDU reached the device.
  LedgerException markUnsent() => _UnsentLedgerException(code, message);
  bool get unsent => this is _UnsentLedgerException;
}

class _UnsentLedgerException extends LedgerException {
  const _UnsentLedgerException(super.code, super.message);
}
