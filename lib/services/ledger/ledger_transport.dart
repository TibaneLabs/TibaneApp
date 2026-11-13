import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'ledger_ble.dart';
import 'ledger_usb.dart';

export 'ledger_framing.dart' show LedgerFramingException;

/// A link to one Ledger that carries raw APDUs. libwallet does every protocol
/// step above this (`client.ledger.bridge(transport.exchange)`).
abstract class LedgerTransport {
  /// What the device calls itself ("Nano X 1A2B", "Ledger Nano S Plus").
  String get name;

  /// `usb` or `ble`.
  String get kind;

  /// Send one APDU, return the full answer, status word included. Calls are
  /// serialized: one APDU is in flight at a time. Throws [LedgerException].
  Future<Uint8List> exchange(Uint8List apdu);

  /// Release the device. The transport cannot be used afterwards.
  Future<void> close();

  /// False once closed, or while the device is gone (unplugged, out of range,
  /// re-enumerating after opening an app). A transport that lost its device
  /// but was not closed tries to reconnect on the next [exchange].
  bool get isOpen;
}

/// A transport-level failure. [code] is stable and meant for the UI to map to
/// a localized message; [message] is diagnostic English.
class LedgerException implements Exception {
  /// No Ledger found, or the chosen one is gone.
  static const noDevice = 'NO_DEVICE';

  /// The user (or the OS) refused USB or Bluetooth access.
  static const permissionDenied = 'PERMISSION_DENIED';

  /// This phone cannot do it (no USB host, no BLE, iOS USB, not a Ledger).
  static const unsupported = 'UNSUPPORTED';

  /// The link dropped (unplugged, out of range, closed).
  static const disconnected = 'DISCONNECTED';

  /// Bluetooth is turned off.
  static const bluetoothOff = 'BLUETOOTH_OFF';

  /// The device did not answer in time.
  static const timeout = 'TIMEOUT';

  /// Anything else on the wire.
  static const io = 'IO';

  final String code;
  final String message;

  const LedgerException(this.code, this.message);

  @override
  String toString() => 'LedgerException($code): $message';
}

/// A Ledger that can be opened.
class LedgerDeviceInfo {
  /// USB: the Android device path. BLE: the platform remote id.
  final String id;
  final String name;

  /// `usb` or `ble`.
  final String kind;

  /// Signal strength of the last BLE advertisement; null for USB.
  final int? rssi;

  const LedgerDeviceInfo({
    required this.id,
    required this.name,
    required this.kind,
    this.rssi,
  });

  bool get isUsb => kind == 'usb';
  bool get isBle => kind == 'ble';

  @override
  bool operator ==(Object other) =>
      other is LedgerDeviceInfo && other.id == id && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, kind);

  @override
  String toString() =>
      'LedgerDeviceInfo($kind:$id "$name"${rssi != null ? ' $rssi dBm' : ''})';
}

enum LedgerConnectionStatus {
  /// No transport, or the current one lost its device.
  disconnected,

  /// Opening (or reconnecting) a device.
  connecting,

  /// Ready for APDUs.
  connected,
}

class LedgerConnectionState {
  final LedgerConnectionStatus status;

  /// The device being opened or in use; null when nothing was opened.
  final LedgerDeviceInfo? device;

  /// The [LedgerException.code] that caused the last drop or failed open.
  final String? errorCode;

  const LedgerConnectionState(this.status, {this.device, this.errorCode});

  static const idle = LedgerConnectionState(
    LedgerConnectionStatus.disconnected,
  );

  bool get isConnected => status == LedgerConnectionStatus.connected;

  @override
  String toString() =>
      'LedgerConnectionState(${status.name}, $device, $errorCode)';
}

/// Runs async tasks one at a time, in call order.
class LedgerSerialLock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}

/// Finds Ledgers over USB (Android only) and Bluetooth LE, and holds the one
/// open transport.
class LedgerConnector {
  LedgerConnector._();

  static final LedgerConnector instance = LedgerConnector._();

  factory LedgerConnector() => instance;

  final ValueNotifier<LedgerConnectionState> _state = ValueNotifier(
    LedgerConnectionState.idle,
  );
  final LedgerSerialLock _openLock = LedgerSerialLock();
  LedgerTransport? _current;

  /// Connection state of [current], for the UI.
  ValueListenable<LedgerConnectionState> get state => _state;

  /// The open (or reconnectable) transport, if any.
  LedgerTransport? get current => _current;

  static bool get _android => !kIsWeb && Platform.isAndroid;
  static bool get _mobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// USB-OTG: Android with USB host mode. iOS has no USB HID API for apps.
  Future<bool> get usbSupported async =>
      _android && await LedgerUsb.isSupported();

  /// Bluetooth LE hardware present (it may still be off or unauthorized).
  Future<bool> get bleSupported async =>
      _mobile && await LedgerBle.isSupported();

  /// Ledgers plugged in over USB. Empty on iOS.
  Future<List<LedgerDeviceInfo>> listUsb() async {
    if (!_android) return const [];
    return LedgerUsb.list();
  }

  /// Scan for Ledgers advertising over BLE. Emits the accumulated list (each
  /// device once, latest RSSI) and closes after [timeout] or [stopScan].
  /// Errors are [LedgerException] (`BLUETOOTH_OFF`, `PERMISSION_DENIED`,
  /// `UNSUPPORTED`).
  Stream<List<LedgerDeviceInfo>> scanBle({
    Duration timeout = const Duration(seconds: 15),
  }) {
    if (!_mobile) {
      return Stream.error(
        const LedgerException(
          LedgerException.unsupported,
          'Bluetooth is not available on this platform.',
        ),
      );
    }
    return LedgerBle.scan(timeout: timeout);
  }

  Future<void> stopScan() async {
    if (_mobile) await LedgerBle.stopScan();
  }

  /// Open [device], closing any current transport first. A failed open
  /// leaves the state `disconnected` with the error code and rethrows.
  Future<LedgerTransport> open(LedgerDeviceInfo device) =>
      _openLock.run(() async {
        await _closeCurrentUnlocked();
        _state.value = LedgerConnectionState(
          LedgerConnectionStatus.connecting,
          device: device,
        );
        try {
          final LedgerTransport t;
          if (device.isUsb) {
            if (!_android) {
              throw const LedgerException(
                LedgerException.unsupported,
                'USB Ledgers need Android.',
              );
            }
            t = await LedgerUsbTransport.open(
              device,
              onStatus: (s, code) => _onStatus(device, s, code),
            );
          } else if (device.isBle) {
            if (!_mobile) {
              throw const LedgerException(
                LedgerException.unsupported,
                'Bluetooth is not available on this platform.',
              );
            }
            await LedgerBle.stopScan();
            t = await LedgerBleTransport.open(
              device,
              onStatus: (s, code) => _onStatus(device, s, code),
            );
          } else {
            throw LedgerException(
              LedgerException.unsupported,
              'Unknown transport ${device.kind}.',
            );
          }
          _current = t;
          _state.value = LedgerConnectionState(
            LedgerConnectionStatus.connected,
            device: device,
          );
          return t;
        } catch (e) {
          final err = asLedgerException(e);
          _state.value = LedgerConnectionState(
            LedgerConnectionStatus.disconnected,
            device: device,
            errorCode: err.code,
          );
          throw err;
        }
      });

  /// Close and forget the current transport.
  Future<void> closeCurrent() => _openLock.run(_closeCurrentUnlocked);

  Future<void> _closeCurrentUnlocked() async {
    final t = _current;
    _current = null;
    if (t != null) {
      try {
        await t.close();
      } catch (_) {}
    }
    _state.value = LedgerConnectionState.idle;
  }

  void _onStatus(
    LedgerDeviceInfo device,
    LedgerConnectionStatus status,
    String? code,
  ) {
    // Only the current transport reports; a closed one has been replaced.
    if (_state.value.device != device) return;
    _state.value = LedgerConnectionState(
      status,
      device: device,
      errorCode: code,
    );
  }
}

/// Status reports from a transport to the connector.
typedef LedgerStatusCallback =
    void Function(LedgerConnectionStatus status, String? errorCode);

/// Turn anything thrown below into a [LedgerException].
LedgerException asLedgerException(Object e) {
  if (e is LedgerException) return e;
  if (e is TimeoutException) {
    return LedgerException(LedgerException.timeout, e.message ?? 'Timed out.');
  }
  return LedgerException(LedgerException.io, e.toString());
}
