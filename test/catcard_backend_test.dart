import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/catcard/apdu.dart';
import 'package:tibaneapp/services/catcard/catcard_wallet_backend.dart';
import 'package:tibaneapp/services/catcard/client.dart';
import 'package:tibaneapp/services/catcard/hostwallet.dart';
import 'package:tibaneapp/services/catcard/ncry.dart';
import 'package:tibaneapp/services/catcard/wire.dart';

/// The whole phone side -- APDUs, pairing, the channel, host-wallet -- against
/// a CatCard simulated at the card's edge: it parses the same APDUs the
/// firmware does and runs the device half of the handshake with its own key.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const solAddress = 'So1anaAddress11111111111111111111111111111111';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('client: identify, pair with the code compared, run a sealed ping', () async {
    final device = FakeCatCard(solanaAddress: solAddress);
    final client = CatCardClient(ApduTransport(device));
    final id = await client.identify();
    expect(id.board, 'q1');
    expect(id.usable, isTrue);
    final code = await client.beginPairing();
    expect(code, device.shownCode);
    expect(client.paired, isFalse);
    device.ownerAccepts();
    await client.confirmPairing(pollInterval: Duration.zero);
    expect(client.paired, isTrue);
    final r = await client.sealed(Opcode.ping, Uint8List.fromList([1, 2]));
    expect(r.ok, isTrue);
    expect(r.body, [1, 2]);
  });

  test('client: a different code sends PairAbort and the prompt goes away', () async {
    final device = FakeCatCard(solanaAddress: solAddress);
    final client = CatCardClient(ApduTransport(device));
    await client.beginPairing();
    expect(device.promptUp, isTrue);
    await client.abortPairing();
    expect(device.promptUp, isFalse);
    expect(client.paired, isFalse);
  });

  test('client: the device owner refusing is Declined', () async {
    final device = FakeCatCard(solanaAddress: solAddress);
    final client = CatCardClient(ApduTransport(device));
    await client.beginPairing();
    device.ownerRefuses();
    await expectLater(
      client.confirmPairing(pollInterval: Duration.zero),
      throwsA(isA<CatCardDeclined>()),
    );
  });

  test('client: a locked device refuses to pair', () async {
    final device = FakeCatCard(solanaAddress: solAddress, unlocked: false);
    final client = CatCardClient(ApduTransport(device));
    await expectLater(
      client.beginPairing(),
      throwsA(isA<CatCardNotNow>().having((e) => e.detail, 'detail', BusyReason.locked)),
    );
  });

  test('backend: connect shares the Solana account and persists it', () async {
    final device = FakeCatCard(solanaAddress: solAddress, autoApprove: true);
    final backend = CatCardWalletBackend();
    backend.openCard = ({String? name}) async => device;
    backend.codeConfirmer = (code) async {
        expect(code, device.shownCode);
        return true;
      };
    final statuses = <String>[];
    backend.statusListener = statuses.add;
    expect(await backend.connect(), isTrue, reason: backend.error);
    expect(backend.isConnected, isTrue);
    expect(backend.publicKey, solAddress);
    expect(backend.path?.text, 'm/44h/501h/0h/0h');
    expect(backend.account, 0);
    expect(backend.walletName, 'CatCard Q1');
    expect(backend.sessionOpen, isTrue);
    expect(statuses, contains('Pairing with the CatCard…'));

    // A new backend restores the account from prefs without a device.
    final restored = CatCardWalletBackend();
    await restored.tryRestore();
    expect(restored.publicKey, solAddress);
    expect(restored.path?.text, 'm/44h/501h/0h/0h');
    expect(restored.sessionOpen, isFalse);
  });

  test('backend: a cancelled code comparison leaves nothing connected', () async {
    final device = FakeCatCard(solanaAddress: solAddress, autoApprove: true);
    final backend = CatCardWalletBackend();
    backend.openCard = ({String? name}) async => device;
    backend.codeConfirmer = (code) async => false;
    expect(await backend.connect(), isFalse);
    expect(backend.isConnected, isFalse);
    expect(backend.error, contains('not confirmed'));
    expect(device.promptUp, isFalse);
  });

  test('backend: signing reuses the session and returns the signed tx', () async {
    final device = FakeCatCard(solanaAddress: solAddress, autoApprove: true);
    final backend = CatCardWalletBackend();
    backend.openCard = ({String? name}) async => device;
    backend.codeConfirmer = (code) async => true;
    expect(await backend.connect(), isTrue, reason: backend.error);
    final tx = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
    final signed = await backend.signTransactions([tx]);
    expect(signed.single, isNotNull);
    // The fake "signs" by filling the first 64 bytes with the slot marker.
    expect(signed.single!.sublist(0, 64), List.filled(64, 0x5A));
    expect(signed.single!.sublist(64), tx.sublist(64));
    expect(device.pairings, 1, reason: 'the open session was reused');
    expect(device.lastSignKeys.single.text, 'm/44h/501h/0h/0h');
  });

  test('backend: a fresh session shares the account again before signing', () async {
    final device = FakeCatCard(solanaAddress: solAddress, autoApprove: true);
    final backend = CatCardWalletBackend();
    backend.openCard = ({String? name}) async => device;
    backend.codeConfirmer = (code) async => true;
    expect(await backend.connect(), isTrue, reason: backend.error);
    await backend.endSession();
    expect(backend.isConnected, isTrue);
    final signed = await backend.signTransactions([Uint8List(100)]);
    expect(signed.single, isNotNull);
    expect(device.pairings, 2);
    expect(device.addressShares, 2);
  });

  test('backend: a decline on the device is a null signature, not an error', () async {
    final device = FakeCatCard(solanaAddress: solAddress, autoApprove: true);
    final backend = CatCardWalletBackend();
    backend.openCard = ({String? name}) async => device;
    backend.codeConfirmer = (code) async => true;
    expect(await backend.connect(), isTrue, reason: backend.error);
    device.declineNextSign = true;
    final signed = await backend.signTransactions([Uint8List(100)]);
    expect(signed.single, isNull);
    expect(backend.error, contains('Declined'));
    expect(backend.sessionOpen, isTrue);
  });

  test('backend: messages are not signed', () async {
    final backend = CatCardWalletBackend();
    expect(await backend.signMessage(Uint8List(5)), isNull);
    expect(backend.error, contains('transactions only'));
  });
}

/// A CatCard at its card's edge: APDUs in, the firmware's answers out.
class FakeCatCard implements ApduCard {
  FakeCatCard({
    required this.solanaAddress,
    this.unlocked = true,
    this.autoApprove = false,
  });

  final String solanaAddress;
  final bool unlocked;

  /// Approve pairing prompts and host questions without being asked.
  final bool autoApprove;

  bool declineNextSign = false;

  // Observable state.
  String? shownCode;
  bool promptUp = false;
  int pairings = 0;
  int addressShares = 0;
  List<DerivationPath> lastSignKeys = const [];

  // Device state.
  NcrySession? _session;
  bool _paired = false;
  bool? _ownerAnswer;
  PairingInitiator? _deviceKey;
  Uint8List? _commit;
  final List<DerivationPath> _sharedAccounts = [];
  BytesBuilder? _upload;
  int _uploadChain = 0;
  Uint8List? _result;
  bool _resultIsDecline = false;
  final BytesBuilder _chain = BytesBuilder();

  void ownerAccepts() => _ownerAnswer = true;
  void ownerRefuses() => _ownerAnswer = false;

  @override
  Future<void> close() async {
    _session = null;
    _paired = false;
    promptUp = false;
  }

  @override
  Future<ApduResponse> transmit(Uint8List apdu) async {
    // Extended APDU only: CLA INS P1 P2 00 Lc(2) data Le(2).
    final cla = apdu[0];
    if (apdu[1] != apduInsMessage) return ApduResponse(Uint8List(0), 0x6D00);
    final lc = (apdu[5] << 8) | apdu[6];
    final data = apdu.sublist(7, 7 + lc);
    _chain.add(data);
    if (cla & apduClaChain != 0) return ApduResponse(Uint8List(0), swOk);
    final message = _chain.toBytes();
    _chain.clear();
    final r = ByteReader(message);
    final opcode = r.u16();
    final total = r.u32();
    final payload = Uint8List.fromList(r.rest());
    if (payload.length != total) {
      return _reply(Status.badRequest, [2]);
    }
    final reply = await _dispatch(opcode, payload);
    return _reply(reply.status, reply.body);
  }

  ApduResponse _reply(int status, List<int> body) => ApduResponse(
    (ByteWriter()
          ..u16(status)
          ..u32(body.length)
          ..bytes(body))
        .toBytes(),
    swOk,
  );

  Future<Reply> _dispatch(int opcode, Uint8List payload) async {
    Reply ok([List<int> body = const []]) =>
        Reply(Status.ok, Uint8List.fromList(body));
    Reply st(int s, [List<int> body = const []]) =>
        Reply(s, Uint8List.fromList(body));
    switch (opcode) {
      case Opcode.ping:
        return ok(payload);
      case Opcode.identify:
        return ok(
          (ByteWriter()
                ..u16(2)
                ..u8(unlocked ? DeviceState.unlocked : 0)
                ..u8(Caps.pairing | Caps.hostWallet | Caps.upgrade)
                ..short('q1'.codeUnits)
                ..short('7.0.0'.codeUnits))
              .toBytes(),
        );
      case Opcode.pairCommit:
        if (!unlocked) return st(Status.notNow);
        if (promptUp) return st(Status.busy);
        _commit = payload;
        _deviceKey = await PairingInitiator.create();
        _session = null;
        _paired = false;
        return ok(_deviceKey!.publicKey);
      case Opcode.pairReveal:
        final key = _deviceKey;
        final commit = _commit;
        if (key == null || commit == null) return st(Status.notNow);
        if (!_same(await pairingCommitment(payload), commit)) {
          return st(Status.badRequest);
        }
        final host = await NcrySession.fromHandshake(
          shared: await key.sharedSecretWith(payload),
          commit: commit,
          devicePub: key.publicKey,
          hostPub: payload,
        );
        _session = host.swapped();
        shownCode = _session!.codeText;
        promptUp = true;
        _ownerAnswer = autoApprove ? true : null;
        return ok();
      case Opcode.pairAbort:
        promptUp = false;
        _session = null;
        _paired = false;
        _sharedAccounts.clear();
        return ok();
      case Opcode.ncryMsg:
        final session = _session;
        if (session == null) return st(Status.notNow);
        final Uint8List plain;
        try {
          plain = await session.open(payload);
        } on NcryAuthException {
          _session = null;
          _paired = false;
          return st(Status.notNow);
        }
        final ir = ByteReader(plain);
        final inner = ir.u16();
        final innerPayload = Uint8List.fromList(ir.rest());
        if (!_paired) {
          if (inner != Opcode.pairConfirm) {
            _session = null;
            return st(Status.notNow);
          }
          final answer = _ownerAnswer;
          if (answer == null) {
            return ok(await session.seal((ByteWriter()..u16(Status.notNow)).toBytes()));
          }
          if (!answer) {
            promptUp = false;
            _session = null;
            return st(Status.declined);
          }
          _paired = true;
          promptUp = false;
          pairings++;
          return ok(await session.seal((ByteWriter()..u16(Status.ok)).toBytes()));
        }
        final r = await _dispatch(inner, innerPayload);
        return ok(
          await session.seal(
            (ByteWriter()
                  ..u16(r.status)
                  ..bytes(r.body))
                .toBytes(),
          ),
        );
      case Opcode.hostAddresses:
        if (!_paired) return st(Status.unknownOpcode);
        if (_result != null) return st(Status.notNow, [BusyReason.busy]);
        addressShares++;
        final account = DerivationPath.parse('m/44h/501h/0h');
        final address = DerivationPath.parse('m/44h/501h/0h/0h');
        _sharedAccounts
          ..clear()
          ..add(account);
        final w = ByteWriter()
          ..u8(ResultKind.addresses)
          ..u8(hostWalletVersion)
          ..bytes([0xde, 0xad, 0xbe, 0xef])
          ..u32(0)
          ..u8(1)
          ..u8(AddressShape.account)
          ..u8(ChainId.solana)
          ..u8(AddressFormat.solana);
        account.encode(w);
        address.encode(w);
        w
          ..short(solanaAddress.codeUnits)
          ..short(List.filled(32, 9));
        _result = w.toBytes();
        return ok();
      case Opcode.hostSignBegin:
        if (!_paired) return st(Status.unknownOpcode);
        if (_result != null) return st(Status.notNow, [BusyReason.busy]);
        final r = ByteReader(payload);
        _uploadChain = r.u8();
        if (_uploadChain != ChainId.solana) {
          return st(Status.refused, 'Only Solana here'.codeUnits);
        }
        if (_sharedAccounts.isEmpty) {
          return st(Status.refused, 'nothing shared this session'.codeUnits);
        }
        _upload = BytesBuilder();
        return ok(u32le(hostWalletDataMax));
      case Opcode.hostSignData:
        final up = _upload;
        if (up == null) return st(Status.notNow);
        final r = ByteReader(payload);
        final offset = r.u32();
        if (offset != up.length) return st(Status.badRequest);
        up.add(r.rest());
        return ok(u32le(up.length));
      case Opcode.hostSignCommit:
        final up = _upload;
        if (up == null) return st(Status.notNow);
        _upload = null;
        final blob = ByteReader(up.toBytes());
        if (blob.u8() != hostWalletVersion) return st(Status.refused, 'version'.codeUnits);
        if (blob.u8() != _uploadChain) return st(Status.refused, 'chain'.codeUnits);
        final n = blob.u8();
        final keys = [for (var i = 0; i < n; i++) DerivationPath.decode(blob)];
        final tx = blob.take(blob.u32());
        blob.done();
        for (final k in keys) {
          if (!_sharedAccounts.any(k.isBelow) || !k.hardenedThroughout) {
            return st(Status.refused, 'key not under a shared account'.codeUnits);
          }
        }
        lastSignKeys = keys;
        if (declineNextSign) {
          declineNextSign = false;
          _resultIsDecline = true;
          _result = Uint8List(0);
          return ok();
        }
        final signed = Uint8List.fromList(tx);
        final sig = List.filled(64, 0x5A);
        signed.setRange(0, 64, sig);
        _result = (ByteWriter()
              ..u8(ResultKind.solana)
              ..u8(1)
              ..u8(0)
              ..bytes(sig)
              ..u32(signed.length)
              ..bytes(signed))
            .toBytes();
        return ok();
      case Opcode.hostResult:
        if (!_paired) return st(Status.unknownOpcode);
        final result = _result;
        if (result == null) return st(Status.notNow, [ResultStage.nothing]);
        if (_resultIsDecline) {
          _result = null;
          _resultIsDecline = false;
          return st(Status.declined);
        }
        final offset = ByteReader(payload).u32();
        if (offset > result.length) return st(Status.badRequest);
        final end = offset + hostWalletPageMax < result.length
            ? offset + hostWalletPageMax
            : result.length;
        if (end == result.length) _result = null;
        return ok([...u32le(result.length), ...result.sublist(offset, end)]);
      case Opcode.hostAbort:
        _upload = null;
        _result = null;
        return ok();
    }
    return st(Status.unknownOpcode);
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
