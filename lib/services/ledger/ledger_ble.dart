import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ledger_framing.dart';
import 'ledger_transport.dart';

/// One Ledger model's GATT layout (`@ledgerhq/devices` `bluetoothSpec`). The
/// UUIDs differ only in the fourth group: `0000` service, `0001` notify,
/// `0002` write, `0003` write-without-response.
class LedgerBleSpec {
  final String model;
  final Guid service;
  final Guid notify;
  final Guid write;
  final Guid writeCmd;

  LedgerBleSpec._(this.model, String prefix)
    : service = Guid('$prefix-0000-4c6564676572'),
      notify = Guid('$prefix-0001-4c6564676572'),
      write = Guid('$prefix-0002-4c6564676572'),
      writeCmd = Guid('$prefix-0003-4c6564676572');

  static final List<LedgerBleSpec> all = [
    LedgerBleSpec._('Nano X', '13d63400-2c97-0004'),
    LedgerBleSpec._('Stax', '13d63400-2c97-6004'),
    LedgerBleSpec._('Flex', '13d63400-2c97-3004'),
    // Nano Gen5 ("apex"); listed in recent @ledgerhq/devices, unverified here.
    LedgerBleSpec._('Nano Gen5', '13d63400-2c97-8004'),
  ];

  static List<Guid> get services => [for (final s in all) s.service];
}

/// Scanning, on top of flutter_blue_plus.
class LedgerBle {
  LedgerBle._();

  static Future<bool> isSupported() async {
    try {
      return await FlutterBluePlus.isSupported;
    } catch (_) {
      return false;
    }
  }

  /// Wait out the adapter's initial `unknown`, then fail unless it is on.
  static Future<void> ensureOn() async {
    BluetoothAdapterState s;
    try {
      s = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => FlutterBluePlus.adapterStateNow,
          );
    } catch (e) {
      throw mapBleError(e);
    }
    switch (s) {
      case BluetoothAdapterState.on:
        return;
      case BluetoothAdapterState.unauthorized:
        throw const LedgerException(
          LedgerException.permissionDenied,
          'Bluetooth access was not allowed.',
        );
      case BluetoothAdapterState.unavailable:
        throw const LedgerException(
          LedgerException.unsupported,
          'This phone has no Bluetooth LE.',
        );
      default:
        throw const LedgerException(
          LedgerException.bluetoothOff,
          'Bluetooth is off.',
        );
    }
  }

  static Stream<List<LedgerDeviceInfo>> scan({required Duration timeout}) {
    late StreamController<List<LedgerDeviceInfo>> out;
    StreamSubscription<List<ScanResult>>? results;
    StreamSubscription<bool>? scanning;
    final found = <String, LedgerDeviceInfo>{};

    void emit() {
      if (!out.isClosed) out.add(List.unmodifiable(found.values));
    }

    Future<void> finish() async {
      await results?.cancel();
      await scanning?.cancel();
      results = null;
      scanning = null;
      if (!out.isClosed) await out.close();
    }

    Future<void> start() async {
      try {
        await ensureOn();
        // A Ledger already connected to the phone (bonded, or held by
        // another app) does not advertise; list those too.
        try {
          for (final d in await FlutterBluePlus.systemDevices(
            LedgerBleSpec.services,
          )) {
            found[d.remoteId.str] = LedgerDeviceInfo(
              id: d.remoteId.str,
              name: _nameOf(d.platformName, d.advName),
              kind: 'ble',
            );
          }
          if (found.isNotEmpty) emit();
        } catch (_) {}
        results = FlutterBluePlus.onScanResults.listen(
          (list) {
            for (final r in list) {
              found[r.device.remoteId.str] = LedgerDeviceInfo(
                id: r.device.remoteId.str,
                name: _nameOf(
                  r.advertisementData.advName,
                  r.device.platformName,
                ),
                kind: 'ble',
                rssi: r.rssi,
              );
            }
            emit();
          },
          onError: (Object e) {
            if (!out.isClosed) out.addError(mapBleError(e));
          },
        );
        await FlutterBluePlus.startScan(
          withServices: LedgerBleSpec.services,
          timeout: timeout,
        );
        // Ends on timeout or stopScan (also from another caller).
        scanning = FlutterBluePlus.isScanning
            .where((s) => !s)
            .listen((_) => finish());
      } catch (e) {
        if (!out.isClosed) out.addError(asBle(e));
        await finish();
      }
    }

    out = StreamController<List<LedgerDeviceInfo>>(
      onListen: start,
      onCancel: () async {
        await finish();
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {}
      },
    );
    return out.stream;
  }

  static Future<void> stopScan() async {
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  static String _nameOf(String a, String b) =>
      a.isNotEmpty ? a : (b.isNotEmpty ? b : 'Ledger');

  static LedgerException asBle(Object e) =>
      e is LedgerException ? e : mapBleError(e);

  static LedgerException mapBleError(Object e) {
    if (e is LedgerException) return e;
    if (e is TimeoutException) {
      return LedgerException(
        LedgerException.timeout,
        e.message ?? 'Bluetooth timed out.',
      );
    }
    final text = e.toString();
    final lower = text.toLowerCase();
    if (e is FlutterBluePlusException && e.platform == ErrorPlatform.fbp) {
      final code = e.code;
      if (code == FbpErrorCode.timeout.index) {
        return LedgerException(LedgerException.timeout, text);
      }
      if (code == FbpErrorCode.deviceIsDisconnected.index ||
          code == FbpErrorCode.connectionCanceled.index) {
        return LedgerException(LedgerException.disconnected, text);
      }
      if (code == FbpErrorCode.adapterIsOff.index) {
        return LedgerException(LedgerException.bluetoothOff, text);
      }
      if (code == FbpErrorCode.serviceNotFound.index ||
          code == FbpErrorCode.characteristicNotFound.index) {
        return LedgerException(LedgerException.unsupported, text);
      }
    }
    if (lower.contains('permission') || lower.contains('unauthorized')) {
      return LedgerException(LedgerException.permissionDenied, text);
    }
    if (lower.contains('adapter') && lower.contains('off')) {
      return LedgerException(LedgerException.bluetoothOff, text);
    }
    if (lower.contains('disconnect')) {
      return LedgerException(LedgerException.disconnected, text);
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return LedgerException(LedgerException.timeout, text);
    }
    return LedgerException(LedgerException.io, text);
  }
}

/// A Ledger over Bluetooth LE.
///
/// The first connection to a Ledger pairs it: the device shows a code and the
/// phone asks to confirm it, which is why the first notify/write steps get a
/// long timeout. If the link drops while not closed, the next [exchange]
/// reconnects to the same device once; an APDU whose first frame could not be
/// written is resent after that.
class LedgerBleTransport implements LedgerTransport {
  LedgerBleTransport._(this._info, this._device, this._onStatus);

  static const _connectTimeout = Duration(seconds: 20);
  static const _pairingTimeoutSeconds = 60;
  static const _mtuTimeout = Duration(seconds: 10);
  static const _exchangeTimeout = Duration(minutes: 5);

  final LedgerDeviceInfo _info;
  final BluetoothDevice _device;
  final LedgerStatusCallback? _onStatus;
  final LedgerSerialLock _lock = LedgerSerialLock();

  BluetoothCharacteristic? _write;
  bool _writeWithoutResponse = false;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  int _mtu = ledgerBleDefaultMtu;
  bool _open = false;
  bool _closed = false;

  LedgerBleReassembler? _pending;
  Completer<Uint8List>? _answer;
  Completer<int>? _mtuAnswer;

  String _model = 'Ledger';

  /// Frame size the device reported (or the default).
  int get mtu => _mtu;

  /// Model whose GATT service matched.
  String get model => _model;

  static Future<LedgerBleTransport> open(
    LedgerDeviceInfo info, {
    LedgerStatusCallback? onStatus,
  }) async {
    await LedgerBle.ensureOn();
    final t = LedgerBleTransport._(
      info,
      BluetoothDevice.fromId(info.id),
      onStatus,
    );
    try {
      await t._connect();
    } catch (e) {
      await t._teardown();
      throw LedgerBle.asBle(e);
    }
    return t;
  }

  Future<void> _connect() async {
    await _teardown();
    // Android requests a large ATT MTU right after connecting; the Ledger
    // then tells us the frame size it accepts.
    await _device.connect(timeout: _connectTimeout);
    final services = await _device.discoverServices();
    LedgerBleSpec? spec;
    BluetoothService? service;
    for (final s in services) {
      for (final candidate in LedgerBleSpec.all) {
        if (s.uuid == candidate.service) {
          spec = candidate;
          service = s;
        }
      }
    }
    if (spec == null || service == null) {
      throw const LedgerException(
        LedgerException.unsupported,
        'Not a Ledger (no Ledger GATT service).',
      );
    }
    _model = spec.model;
    BluetoothCharacteristic? notify, write, writeCmd;
    for (final c in service.characteristics) {
      if (c.uuid == spec.notify) notify = c;
      if (c.uuid == spec.write) write = c;
      if (c.uuid == spec.writeCmd) writeCmd = c;
    }
    if (notify == null || (write == null && writeCmd == null)) {
      throw const LedgerException(
        LedgerException.unsupported,
        'Ledger GATT characteristics missing.',
      );
    }
    // Prefer acknowledged writes: frames arrive in order and each is
    // flow-controlled; fall back to write-without-response.
    if (write != null && write.properties.write) {
      _write = write;
      _writeWithoutResponse = false;
    } else {
      _write = writeCmd ?? write;
      _writeWithoutResponse = true;
    }

    _notifySub = notify.onValueReceived.listen(_onFrame);
    _device.cancelWhenDisconnected(_notifySub!);
    _stateSub = _device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && _open) {
        _lost(LedgerException.disconnected);
      }
    });
    // Subscribing may trigger pairing on first use.
    await notify.setNotifyValue(true, timeout: _pairingTimeoutSeconds);

    _mtu = await _queryMtu();
    _open = true;
  }

  Future<int> _queryMtu() async {
    final c = Completer<int>();
    _mtuAnswer = c;
    try {
      await _writeFrame(
        ledgerBleMtuRequest(),
        timeoutSeconds: _pairingTimeoutSeconds,
      );
      final m = await c.future.timeout(_mtuTimeout);
      return m >= 6 ? m : ledgerBleDefaultMtu;
    } on TimeoutException {
      debugPrint('LedgerBle: no MTU answer, using $ledgerBleDefaultMtu');
      return ledgerBleDefaultMtu;
    } finally {
      _mtuAnswer = null;
    }
  }

  void _onFrame(List<int> value) {
    final frame = Uint8List.fromList(value);
    if (frame.isEmpty) return;
    if (frame[0] == ledgerBleMtuTag) {
      final m = ledgerBleParseMtu(frame);
      final c = _mtuAnswer;
      if (m != null && c != null && !c.isCompleted) c.complete(m);
      return;
    }
    final r = _pending;
    final c = _answer;
    if (r == null || c == null || c.isCompleted) return; // stray notification
    try {
      final done = r.add(frame);
      if (done != null) c.complete(done);
    } on LedgerFramingException catch (e) {
      c.completeError(LedgerException(LedgerException.io, e.message));
    }
  }

  Future<void> _writeFrame(Uint8List frame, {int timeoutSeconds = 15}) async {
    final w = _write;
    if (w == null) {
      throw const LedgerException(
        LedgerException.disconnected,
        'Not connected.',
      );
    }
    await w.write(
      frame,
      withoutResponse: _writeWithoutResponse,
      timeout: timeoutSeconds,
    );
  }

  void _lost(String code) {
    _open = false;
    final c = _answer;
    if (c != null && !c.isCompleted) {
      c.completeError(
        const LedgerException(
          LedgerException.disconnected,
          'The Ledger disconnected.',
        ),
      );
    }
    if (!_closed) _onStatus?.call(LedgerConnectionStatus.disconnected, code);
  }

  Future<void> _teardown() async {
    await _notifySub?.cancel();
    await _stateSub?.cancel();
    _notifySub = null;
    _stateSub = null;
    _write = null;
  }

  @override
  String get name => _info.name;

  @override
  String get kind => 'ble';

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
    } on _Unsent catch (e) {
      if (_closed || e.error.code != LedgerException.disconnected) {
        throw e.error;
      }
      _lost(e.error.code);
      await _reconnect();
      try {
        return await _send(apdu);
      } on _Unsent catch (e2) {
        throw e2.error;
      }
    }
  });

  Future<void> _reconnect() async {
    _onStatus?.call(LedgerConnectionStatus.connecting, null);
    try {
      await LedgerBle.ensureOn();
      await _connect();
      _onStatus?.call(LedgerConnectionStatus.connected, null);
    } catch (e) {
      final err = LedgerBle.asBle(e);
      _onStatus?.call(LedgerConnectionStatus.disconnected, err.code);
      throw err;
    }
  }

  Future<Uint8List> _send(Uint8List apdu) async {
    final frames = ledgerBleFrames(apdu, _mtu);
    final answer = Completer<Uint8List>();
    _pending = LedgerBleReassembler();
    _answer = answer;
    try {
      for (var i = 0; i < frames.length; i++) {
        try {
          await _writeFrame(frames[i]);
        } catch (e) {
          final err = LedgerBle.asBle(e);
          if (i == 0) throw _Unsent(err);
          throw err;
        }
      }
      final r = await answer.future.timeout(
        _exchangeTimeout,
        onTimeout: () => throw const LedgerException(
          LedgerException.timeout,
          'The Ledger did not answer.',
        ),
      );
      if (r.length < 2) {
        throw const LedgerException(
          LedgerException.io,
          'Answer has no status word.',
        );
      }
      return r;
    } finally {
      _pending = null;
      _answer = null;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _open = false;
    final c = _answer;
    if (c != null && !c.isCompleted) {
      c.completeError(
        const LedgerException(
          LedgerException.disconnected,
          'The Ledger link was closed.',
        ),
      );
    }
    await _teardown();
    try {
      await _device.disconnect();
    } catch (_) {}
  }
}

/// A send that failed before its first frame left the phone.
class _Unsent implements Exception {
  final LedgerException error;
  _Unsent(this.error);
}
