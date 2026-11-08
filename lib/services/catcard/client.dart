import 'dart:async';

import 'package:flutter/foundation.dart';

import 'hostwallet.dart';
import 'ncry.dart';
import 'transport.dart';
import 'wire.dart';

/// A CatCard reached over one [CatCardTransport]: first contact, pairing,
/// and the paired channel the host-wallet commands run on
/// (docs/PHONE-APP.md §3, §4, §8).
///
/// Pairing is two steps with a person in between: [beginPairing] runs the
/// handshake and returns the code to show; once the person taps "same code"
/// [confirmPairing] tells the device and waits for its owner's answer. If the
/// person taps "different", [abortPairing] takes the prompt off the device.
class CatCardClient {
  CatCardClient(this.transport);

  final CatCardTransport transport;

  CatCardIdentity? _identity;
  NcrySession? _pending;
  NcrySession? _session;

  /// The last `Identify`, if one was read.
  CatCardIdentity? get identity => _identity;

  bool get paired => _session != null;

  /// The host-wallet flows, over [sealed].
  late final HostWallet hostWallet = HostWallet(sealed);

  Future<CatCardIdentity> identify() async {
    final r = await transport.request(Opcode.identify);
    if (!r.ok) {
      throw CatCardProtocolException('Identify: ${Status.name(r.status)}');
    }
    final id = CatCardIdentity.parse(r.body);
    _identity = id;
    return id;
  }

  /// Echo up to 64 bytes.
  Future<Uint8List> ping([List<int> payload = const []]) async {
    final r = await transport.request(Opcode.ping, Uint8List.fromList(payload));
    if (!r.ok) throw CatCardProtocolException('Ping: ${Status.name(r.status)}');
    return r.body;
  }

  /// Commit and reveal. Returns the six-digit code as `ddd ddd` for the
  /// screen; the device shows the same and asks its owner.
  ///
  /// One handshake per tap: the device charges a cooldown per handshake and
  /// blocks after three abandoned ones, so a caller must not retry in a loop.
  Future<String> beginPairing() async {
    final id = _identity ?? await identify();
    if (!id.usable) {
      throw CatCardException(
        'This CatCard does not offer the paired channel '
        '(protocol ${id.protocolVersion}, firmware ${id.version}).',
      );
    }
    if (!id.unlocked) {
      throw CatCardNotNow(
        BusyReason.describe(BusyReason.locked),
        detail: BusyReason.locked,
      );
    }
    _pending = null;
    final init = await PairingInitiator.create();
    final commit = await transport.request(Opcode.pairCommit, init.commit);
    switch (commit.status) {
      case Status.ok:
        break;
      case Status.busy:
        throw CatCardNotNow(
          'The CatCard is busy with a pairing prompt or cooling down; '
          'answer it or wait a few seconds, then try again.',
        );
      case Status.refused:
        throw CatCardRefused(commit.text);
      case Status.notNow:
        throw CatCardNotNow(
          BusyReason.describe(BusyReason.locked),
          detail: BusyReason.locked,
        );
      default:
        throw CatCardProtocolException(
          'PairCommit: ${Status.name(commit.status)}',
        );
    }
    final session = await init.finish(commit.body);
    final reveal = await transport.request(Opcode.pairReveal, init.publicKey);
    if (!reveal.ok) {
      throw CatCardProtocolException('PairReveal: ${Status.name(reveal.status)}');
    }
    _pending = session;
    return session.codeText;
  }

  /// The person tapped "same code": send a sealed `PairConfirm` until the
  /// device's owner has answered too. [onWaitingForDevice] fires once when
  /// the device is still waiting on its owner.
  Future<void> confirmPairing({
    Duration patience = const Duration(seconds: 130),
    Duration pollInterval = const Duration(milliseconds: 500),
    VoidCallback? onWaitingForDevice,
  }) async {
    final session = _pending;
    if (session == null) {
      throw StateError('confirmPairing without beginPairing');
    }
    final deadline = DateTime.now().add(patience);
    var waitingSaid = false;
    while (true) {
      final record = await session.seal(
        (ByteWriter()..u16(Opcode.pairConfirm)).toBytes(),
      );
      final r = await transport.request(Opcode.ncryMsg, record);
      if (r.status == Status.declined) {
        _pending = null;
        throw CatCardDeclined('Pairing was refused on the CatCard.');
      }
      if (!r.ok) {
        _pending = null;
        throw CatCardException(
          'Pairing session ended (${Status.name(r.status)}): the CatCard '
          'timed out or dropped it. Try again.',
        );
      }
      final inner = await session.open(r.body);
      final status = ByteReader(inner).u16();
      if (status == Status.ok) {
        _session = session;
        _pending = null;
        return;
      }
      if (status != Status.notNow) {
        _pending = null;
        throw CatCardProtocolException(
          'PairConfirm: ${Status.name(status)}',
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        await abortPairing();
        throw CatCardException('Nobody answered on the CatCard.');
      }
      if (!waitingSaid) {
        waitingSaid = true;
        onWaitingForDevice?.call();
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// The person tapped "different code" or gave up, or the session is being
  /// torn down: take the prompt off the device. Always safe to call.
  Future<void> abortPairing() async {
    _pending = null;
    _session = null;
    try {
      await transport.request(Opcode.pairAbort);
    } catch (_) {
      // The device may be gone already.
    }
  }

  /// Run one command inside the paired channel and return its inner reply.
  /// Throws [CatCardNotNow] when the session is gone on the device's side.
  Future<Reply> sealed(int opcode, Uint8List payload) async {
    final session = _session;
    if (session == null) {
      throw CatCardException('Not paired with the CatCard.');
    }
    final plain = (ByteWriter()
          ..u16(opcode)
          ..bytes(payload))
        .toBytes();
    final r = await transport.request(Opcode.ncryMsg, await session.seal(plain));
    if (r.status == Status.notNow) {
      _session = null;
      throw CatCardNotNow(
        'The paired session ended; reconnect the CatCard and pair again.',
      );
    }
    if (r.status == Status.declined) {
      _session = null;
      throw CatCardDeclined();
    }
    if (!r.ok) {
      throw CatCardProtocolException('NcryMsg: ${Status.name(r.status)}');
    }
    final Uint8List inner;
    try {
      inner = await session.open(r.body);
    } on NcryAuthException {
      _session = null;
      rethrow;
    }
    final ir = ByteReader(inner);
    final status = ir.u16();
    return Reply(status, Uint8List.fromList(ir.rest()));
  }

  /// End the session politely and release the transport.
  Future<void> close() async {
    if (_session != null || _pending != null) {
      await abortPairing();
    }
    await transport.close();
  }
}
