import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/catcard/hostwallet.dart';
import 'package:tibaneapp/services/catcard/wire.dart';

/// Layouts pinned to `tools/hostwallet.py --selftest` and the Rust tests in
/// `catcard_usb::hostwallet`.
void main() {
  const h = hardenedBit;

  group('paths', () {
    test('parse and text', () {
      expect(DerivationPath.parse("m/84'/0h/0H/0/3").steps, [84 | h, h, h, 0, 3]);
      expect(DerivationPath([44 | h, 501 | h, 7 | h, h]).text, 'm/44h/501h/7h/0h');
      expect(DerivationPath.parse('m/44h/501h/0h/0h').hardenedThroughout, isTrue);
      expect(DerivationPath.parse('m/84h/0h/0h/0/3').hardenedThroughout, isFalse);
    });

    test('a key below an account', () {
      final account = DerivationPath.parse('m/44h/501h/0h');
      expect(DerivationPath.parse('m/44h/501h/0h/0h').isBelow(account), isTrue);
      expect(DerivationPath.parse('m/44h/501h/1h/0h').isBelow(account), isFalse);
      expect(account.isBelow(account), isFalse);
    });

    test('depth is bounded', () {
      expect(() => DerivationPath(const []), throwsArgumentError);
      expect(() => DerivationPath(List.filled(9, 0)), throwsArgumentError);
    });
  });

  test('the sign blob', () {
    final blob = encodeSignBlob(
      chain: ChainId.bitcoin,
      keys: [DerivationPath.parse('m/84h/0h/0h/0/3')],
      tx: 'psbt'.codeUnits,
    );
    expect(blob, [
      1, 1, 1, //
      5, 84, 0, 0, 0x80, 0, 0, 0, 0x80, 0, 0, 0, 0x80, 0, 0, 0, 0, 3, 0, 0, 0, //
      4, 0, 0, 0, 0x70, 0x73, 0x62, 0x74,
    ]);
  });

  test('an address reply', () {
    final reply = Uint8List.fromList([
      ResultKind.addresses, 1, 0xde, 0xad, 0xbe, 0xef, 7, 0, 0, 0, 2,
      // A Bitcoin P2WPKH account entry.
      1, 1, 3,
      3, 84, 0, 0, 0x80, 0, 0, 0, 0x80, 0, 0, 0, 0x80,
      5, 84, 0, 0, 0x80, 0, 0, 0, 0x80, 0, 0, 0, 0x80, 0, 0, 0, 0, 0, 0, 0, 0,
      4, ...'xpub'.codeUnits, 4, ...'bc1q'.codeUnits, 2, 2, 3,
      // A Solana account entry.
      2, 3, 7,
      3, 44, 0, 0, 0x80, 0xf5, 1, 0, 0x80, 7, 0, 0, 0x80,
      4, 44, 0, 0, 0x80, 0xf5, 1, 0, 0x80, 7, 0, 0, 0x80, 0, 0, 0, 0x80,
      3, ...'So1'.codeUnits, 1, 9,
    ]);
    final r = AddressesReply.parse(reply);
    expect(hexOf(r.fingerprint), 'deadbeef');
    expect(r.account, 7);
    expect(r.entries, hasLength(2));
    final btc = r.entries[0];
    expect(btc.shape, AddressShape.utxo);
    expect(btc.chain, ChainId.bitcoin);
    expect(btc.format, AddressFormat.p2wpkh);
    expect(btc.accountPath.text, 'm/84h/0h/0h');
    expect(btc.addressPath.text, 'm/84h/0h/0h/0/0');
    expect(btc.xpub, 'xpub');
    expect(btc.address, 'bc1q');
    expect(btc.publicKey, [2, 3]);
    final sol = r.entries[1];
    expect(sol.isSolana, isTrue);
    expect(sol.shape, AddressShape.account);
    expect(sol.format, AddressFormat.solana);
    expect(sol.accountPath.text, 'm/44h/501h/7h');
    expect(sol.addressPath.text, 'm/44h/501h/7h/0h');
    expect(sol.xpub, '');
    expect(sol.address, 'So1');
    expect(sol.publicKey, [9]);
    expect(r.solana.single, same(sol));
  });

  test('a Solana result', () {
    final sig = List.filled(64, 0xAA);
    final r = SolanaSignResult.parse(
      Uint8List.fromList([ResultKind.solana, 1, 0, ...sig, 3, 0, 0, 0, 1, 2, 3]),
    );
    expect(r.signatures.single.slot, 0);
    expect(r.signatures.single.bytes, sig);
    expect(r.transaction, [1, 2, 3]);
    expect(
      () => SolanaSignResult.parse(Uint8List.fromList([ResultKind.evm, 0])),
      throwsA(isA<CatCardProtocolException>()),
    );
  });

  group('flows', () {
    test('addresses: queued, the person decides, then two pages', () async {
      final result = Uint8List.fromList([
        ResultKind.addresses, 1, 1, 2, 3, 4, 0, 0, 0, 0, 1,
        2, 3, 7,
        3, 44, 0, 0, 0x80, 0xf5, 1, 0, 0x80, 0, 0, 0, 0x80,
        4, 44, 0, 0, 0x80, 0xf5, 1, 0, 0x80, 0, 0, 0, 0x80, 0, 0, 0, 0x80,
        3, ...'So1'.codeUnits, 1, 9,
      ]);
      final device = _FakeDevice(result: result, pageSize: 20, decidingPolls: 2);
      final stages = <int>[];
      final hw = HostWallet(device.call, pollInterval: Duration.zero);
      final r = await hw.addresses(onStage: stages.add);
      expect(r.solana.single.address, 'So1');
      expect(stages, [ResultStage.onScreen]);
      expect(device.log.first, (Opcode.hostAddresses, 0));
      // Result polls: two NotNow, one first page, then pages at rising offsets.
      final polls = device.log.where((e) => e.$1 == Opcode.hostResult).toList();
      expect(polls.length, 2 + (result.length / 20).ceil());
    });

    test('sign: chunks in order at the announced size, then the result', () async {
      final result = Uint8List.fromList([
        ResultKind.solana, 1, 0, ...List.filled(64, 7), 2, 0, 0, 0, 0xAB, 0xCD,
      ]);
      final device = _FakeDevice(result: result, pageSize: 448, chunk: 10);
      final hw = HostWallet(device.call, pollInterval: Duration.zero);
      final tx = Uint8List.fromList(List.generate(25, (i) => i));
      final out = await hw.sign(
        chain: ChainId.solana,
        keys: [DerivationPath.parse('m/44h/501h/0h/0h')],
        tx: tx,
      );
      final parsed = SolanaSignResult.parse(out);
      expect(parsed.transaction, [0xAB, 0xCD]);
      final data = device.log.where((e) => e.$1 == Opcode.hostSignData).toList();
      // Blob: 3 + (1 + 16) + 4 + 25 = 49 bytes, in chunks of 10.
      expect(data.length, 5);
      expect(device.uploaded, encodeSignBlob(
        chain: ChainId.solana,
        keys: [DerivationPath.parse('m/44h/501h/0h/0h')],
        tx: tx,
      ));
      expect(device.log.any((e) => e.$1 == Opcode.hostSignCommit), isTrue);
      expect(device.log.any((e) => e.$1 == Opcode.hostAbort), isFalse);
    });

    test('sign: a refusal at commit surfaces its reason', () async {
      final device = _FakeDevice(result: Uint8List(0), refuseCommit: 'not shared');
      final hw = HostWallet(device.call, pollInterval: Duration.zero);
      await expectLater(
        hw.sign(
          chain: ChainId.solana,
          keys: [DerivationPath.parse('m/44h/501h/0h/0h')],
          tx: [1],
        ),
        throwsA(isA<CatCardRefused>().having((e) => e.message, 'reason', 'not shared')),
      );
    });

    test('sign: a failed upload is aborted', () async {
      final device = _FakeDevice(result: Uint8List(0), failData: true);
      final hw = HostWallet(device.call, pollInterval: Duration.zero);
      await expectLater(
        hw.sign(
          chain: ChainId.solana,
          keys: [DerivationPath.parse('m/44h/501h/0h/0h')],
          tx: [1],
        ),
        throwsA(isA<CatCardProtocolException>()),
      );
      expect(device.log.last.$1, Opcode.hostAbort);
    });

    test('the person declines', () async {
      final device = _FakeDevice(result: Uint8List(0), decline: true);
      final hw = HostWallet(device.call, pollInterval: Duration.zero);
      await expectLater(hw.addresses(), throwsA(isA<CatCardDeclined>()));
    });

    test('a locked device says so', () async {
      final device = _FakeDevice(result: Uint8List(0), locked: true);
      final hw = HostWallet(device.call, pollInterval: Duration.zero);
      await expectLater(
        hw.addresses(),
        throwsA(isA<CatCardNotNow>().having((e) => e.detail, 'detail', BusyReason.locked)),
      );
    });
  });
}

/// A device answering the host-wallet commands as the real one would, minus
/// the person: it approves after [decidingPolls] polls.
class _FakeDevice {
  _FakeDevice({
    required this.result,
    this.pageSize = hostWalletPageMax,
    this.chunk = hostWalletDataMax,
    this.decidingPolls = 1,
    this.refuseCommit,
    this.failData = false,
    this.decline = false,
    this.locked = false,
  });

  final Uint8List result;
  final int pageSize;
  final int chunk;
  final int decidingPolls;
  final String? refuseCommit;
  final bool failData;
  final bool decline;
  final bool locked;

  final List<(int, int)> log = [];
  final BytesBuilder _upload = BytesBuilder();
  Uint8List get uploaded => _upload.toBytes();
  int _polls = 0;
  bool _asked = false;

  Future<Reply> call(int opcode, Uint8List payload) async {
    log.add((opcode, payload.length));
    Reply ok([List<int> body = const []]) =>
        Reply(Status.ok, Uint8List.fromList(body));
    switch (opcode) {
      case Opcode.hostAddresses:
        if (locked) return Reply(Status.notNow, Uint8List.fromList([1]));
        _asked = true;
        return ok();
      case Opcode.hostSignBegin:
        if (locked) return Reply(Status.notNow, Uint8List.fromList([1]));
        return ok(u32le(chunk));
      case Opcode.hostSignData:
        if (failData) return Reply(Status.badRequest, Uint8List(0));
        final r = ByteReader(payload);
        final offset = r.u32();
        expect(offset, _upload.length, reason: 'chunks in order');
        final bytes = r.rest();
        expect(bytes.length, lessThanOrEqualTo(chunk));
        _upload.add(bytes);
        return ok(u32le(_upload.length));
      case Opcode.hostSignCommit:
        if (refuseCommit != null) {
          return Reply(Status.refused, Uint8List.fromList(refuseCommit!.codeUnits));
        }
        _asked = true;
        return ok();
      case Opcode.hostAbort:
        return ok();
      case Opcode.hostResult:
        if (!_asked) return Reply(Status.notNow, Uint8List.fromList([0]));
        if (_polls < decidingPolls) {
          _polls++;
          return Reply(Status.notNow, Uint8List.fromList([ResultStage.onScreen]));
        }
        if (decline) return Reply(Status.declined, Uint8List(0));
        final offset = ByteReader(payload).u32();
        final end = offset + pageSize < result.length ? offset + pageSize : result.length;
        return ok([...u32le(result.length), ...result.sublist(offset, end)]);
    }
    return Reply(Status.unknownOpcode, Uint8List(0));
  }
}
