import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'wire.dart';

/// Host-wallet commands: ask a CatCard for addresses, or for a signature
/// (docs/PHONE-APP.md §5-7; `catcard_usb::hostwallet`; reference
/// `tools/hostwallet.py`).
///
/// The host asks, the device shows the question to the person holding it,
/// the person decides on the device, and the host polls `HostResult` until
/// there is an answer. Nothing here can answer for the person.

const int hostWalletVersion = 1;
const int hostWalletMaxDepth = 8;
const int hostWalletMaxKeys = 32;

/// Most result bytes one `HostResult` page carries.
const int hostWalletPageMax = 448;

/// Most transaction bytes one `HostSignData` carries.
const int hostWalletDataMax = 1024 - 2 - 4;

/// The hardened bit of a path step.
const int hardenedBit = 0x80000000;

/// One-byte chain ids (`catcard_wallet::chain::ChainId`).
abstract final class ChainId {
  static const int bitcoin = 1;
  static const int ethereum = 2;
  static const int solana = 3;
  static const int litecoin = 4;
  static const int dogecoin = 5;
  static const int bitcoinCash = 6;
  static const int monacoin = 7;
  static const int electraProtocol = 8;
  static const int tron = 9;
  static const int namecoin = 10;

  static String name(int id) => switch (id) {
    bitcoin => 'Bitcoin',
    ethereum => 'Ethereum',
    solana => 'Solana',
    litecoin => 'Litecoin',
    dogecoin => 'Dogecoin',
    bitcoinCash => 'Bitcoin Cash',
    monacoin => 'Monacoin',
    electraProtocol => 'Electra Protocol',
    tron => 'Tron',
    namecoin => 'Namecoin',
    _ => 'chain $id',
  };
}

/// The first byte of every result.
abstract final class ResultKind {
  static const int addresses = 1;
  static const int bitcoin = 2;
  static const int evm = 3;
  static const int solana = 4;
}

abstract final class AddressShape {
  static const int utxo = 1;
  static const int account = 2;
}

abstract final class AddressFormat {
  static const int p2pkh = 1;
  static const int p2shP2wpkh = 2;
  static const int p2wpkh = 3;
  static const int p2tr = 4;
  static const int evm = 5;
  static const int tron = 6;
  static const int solana = 7;
}

/// The byte `NotNow` carries in reply to `HostResult` and `HostAbort`.
abstract final class ResultStage {
  static const int nothing = 0;
  static const int uploading = 1;
  static const int queued = 2;
  static const int onScreen = 3;
  static const int otherSession = 4;

  static String describe(int stage) => switch (stage) {
    nothing => 'nothing asked',
    uploading => 'upload open',
    queued => 'waiting for the device screen',
    onScreen => 'the person is deciding',
    otherSession => 'busy with another session',
    _ => 'stage $stage',
  };
}

/// The byte `NotNow` carries in reply to `HostAddresses` and `HostSignBegin`.
abstract final class BusyReason {
  static const int locked = 1;
  static const int busy = 2;

  static String describe(int reason) => switch (reason) {
    locked => 'the device is locked: enter the PIN first',
    busy => 'another request or an upgrade is pending on the device',
    _ => 'not now ($reason)',
  };
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// A BIP-32 derivation path as the wire carries it: `[u8 depth][depth × u32]`,
/// hardened steps with bit 31 set, depth 1..8.
class DerivationPath {
  DerivationPath(List<int> steps) : steps = List.unmodifiable(steps) {
    if (steps.isEmpty || steps.length > hostWalletMaxDepth) {
      throw ArgumentError('path depth must be 1..$hostWalletMaxDepth');
    }
  }

  final List<int> steps;

  /// `m/84h/0h/0h/0/3` (or with `'`).
  factory DerivationPath.parse(String text) {
    var parts = text.trim().split('/');
    if (parts.isNotEmpty && (parts.first == 'm' || parts.first == 'M')) {
      parts = parts.sublist(1);
    }
    final steps = <int>[];
    for (final p in parts) {
      if (p.isEmpty) throw FormatException('empty path step in "$text"');
      final hard = p.endsWith('h') || p.endsWith('H') || p.endsWith("'");
      final n = int.parse(hard ? p.substring(0, p.length - 1) : p);
      if (n < 0 || n >= hardenedBit) {
        throw FormatException('path step $p out of range');
      }
      steps.add(hard ? n | hardenedBit : n);
    }
    return DerivationPath(steps);
  }

  static DerivationPath decode(ByteReader r) {
    final depth = r.u8();
    if (depth < 1 || depth > hostWalletMaxDepth) {
      throw CatCardProtocolException('bad path depth $depth');
    }
    return DerivationPath([for (var i = 0; i < depth; i++) r.u32()]);
  }

  void encode(ByteWriter w) {
    w.u8(steps.length);
    for (final s in steps) {
      w.u32(s);
    }
  }

  Uint8List toBytes() => (ByteWriter()..also(encode)).toBytes();

  int get depth => steps.length;

  bool get hardenedThroughout => steps.every((s) => s & hardenedBit != 0);

  /// Whether this path is strictly below [account].
  bool isBelow(DerivationPath account) {
    if (steps.length <= account.steps.length) return false;
    for (var i = 0; i < account.steps.length; i++) {
      if (steps[i] != account.steps[i]) return false;
    }
    return true;
  }

  String get text =>
      'm/${steps.map((s) => s & hardenedBit != 0 ? "${s & ~hardenedBit}h" : "$s").join('/')}';

  @override
  String toString() => text;

  @override
  bool operator ==(Object other) =>
      other is DerivationPath && text == other.text;

  @override
  int get hashCode => text.hashCode;
}

extension on ByteWriter {
  void also(void Function(ByteWriter) f) => f(this);
}

// ---------------------------------------------------------------------------
// Layouts
// ---------------------------------------------------------------------------

/// The uploaded sign request:
///
/// ```text
/// [u8 version = 1][u8 chain][u8 key count]
/// key count × [path]
/// [u32 tx length][tx bytes]
/// ```
Uint8List encodeSignBlob({
  required int chain,
  required List<DerivationPath> keys,
  required List<int> tx,
}) {
  if (keys.isEmpty || keys.length > hostWalletMaxKeys) {
    throw ArgumentError('1..$hostWalletMaxKeys keys');
  }
  if (tx.isEmpty) throw ArgumentError('empty transaction');
  final w = ByteWriter()
    ..u8(hostWalletVersion)
    ..u8(chain)
    ..u8(keys.length);
  for (final k in keys) {
    k.encode(w);
  }
  w
    ..u32(tx.length)
    ..bytes(tx);
  return w.toBytes();
}

/// One entry of an address reply.
class AddressEntry {
  const AddressEntry({
    required this.shape,
    required this.chain,
    required this.format,
    required this.accountPath,
    required this.addressPath,
    required this.xpub,
    required this.address,
    required this.publicKey,
  });

  final int shape;
  final int chain;
  final int format;

  /// `m/purpose'/coin'/account'`.
  final DerivationPath accountPath;

  /// Where [address] and [publicKey] are.
  final DerivationPath addressPath;

  /// The account's extended public key, base58; empty for an account chain.
  final String xpub;
  final String address;

  /// 33 bytes compressed secp256k1, or 32 ed25519.
  final Uint8List publicKey;

  bool get isSolana => chain == ChainId.solana;

  @override
  String toString() =>
      '${ChainId.name(chain)} ${addressPath.text} $address';
}

/// `HostAddresses`' result.
class AddressesReply {
  const AddressesReply({
    required this.fingerprint,
    required this.account,
    required this.entries,
  });

  /// The master key fingerprint, four bytes.
  final Uint8List fingerprint;
  final int account;
  final List<AddressEntry> entries;

  Iterable<AddressEntry> get solana => entries.where((e) => e.isSolana);

  static AddressesReply parse(Uint8List bytes) {
    final r = ByteReader(bytes);
    if (r.u8() != ResultKind.addresses) {
      throw CatCardProtocolException('not an address reply');
    }
    if (r.u8() != hostWalletVersion) {
      throw CatCardProtocolException('address reply version not understood');
    }
    final fp = Uint8List.fromList(r.take(4));
    final account = r.u32();
    final n = r.u8();
    final entries = <AddressEntry>[];
    for (var i = 0; i < n; i++) {
      final shape = r.u8();
      if (shape != AddressShape.utxo && shape != AddressShape.account) {
        throw CatCardProtocolException('bad address entry shape $shape');
      }
      final chain = r.u8();
      final format = r.u8();
      final accountPath = DerivationPath.decode(r);
      final addressPath = DerivationPath.decode(r);
      final xpub = shape == AddressShape.utxo ? ascii.decode(r.short()) : '';
      final address = ascii.decode(r.short());
      final pubkey = Uint8List.fromList(r.short());
      entries.add(
        AddressEntry(
          shape: shape,
          chain: chain,
          format: format,
          accountPath: accountPath,
          addressPath: addressPath,
          xpub: xpub,
          address: address,
          publicKey: pubkey,
        ),
      );
    }
    r.done();
    return AddressesReply(fingerprint: fp, account: account, entries: entries);
  }
}

/// One Solana signature: the signer slot it fills and the 64 bytes.
class SolanaSignature {
  const SolanaSignature(this.slot, this.bytes);

  final int slot;
  final Uint8List bytes;
}

/// A Solana sign result:
/// `[u8 kind = 4][u8 n][n × ([u8 slot][64 signature])][u32 len][transaction]`.
/// The transaction carries the signatures in their slots already.
class SolanaSignResult {
  const SolanaSignResult({required this.signatures, required this.transaction});

  final List<SolanaSignature> signatures;
  final Uint8List transaction;

  static SolanaSignResult parse(Uint8List bytes) {
    final r = ByteReader(bytes);
    if (r.u8() != ResultKind.solana) {
      throw CatCardProtocolException('not a Solana result');
    }
    final n = r.u8();
    final sigs = <SolanaSignature>[
      for (var i = 0; i < n; i++)
        SolanaSignature(r.u8(), Uint8List.fromList(r.take(64))),
    ];
    final tx = Uint8List.fromList(r.take(r.u32()));
    r.done();
    return SolanaSignResult(signatures: sigs, transaction: tx);
  }
}

// ---------------------------------------------------------------------------
// Flows
// ---------------------------------------------------------------------------

/// Run one command inside the paired channel; returns its inner reply.
typedef SealedCall = Future<Reply> Function(int opcode, Uint8List payload);

/// The host-wallet flows over a paired session.
class HostWallet {
  HostWallet(
    this.call, {
    this.pollInterval = const Duration(milliseconds: 500),
    this.patience = const Duration(minutes: 15),
  });

  final SealedCall call;

  /// How often `HostResult` is polled while the person decides.
  final Duration pollInterval;

  /// How long to wait for the person before giving up.
  final Duration patience;

  /// Ask for the wallet's addresses. The person picks the account on the
  /// device; [onStage] hears each change of stage while they do.
  Future<AddressesReply> addresses({void Function(int stage)? onStage}) async {
    final r = await call(Opcode.hostAddresses, Uint8List(0));
    switch (r.status) {
      case Status.ok:
        break;
      case Status.notNow:
        throw CatCardNotNow(BusyReason.describe(r.detail), detail: r.detail);
      case Status.unknownOpcode:
        throw CatCardProtocolException(
          'host-wallet commands need a paired channel',
        );
      default:
        throw CatCardProtocolException('HostAddresses: ${Status.name(r.status)}');
    }
    return AddressesReply.parse(await awaitResult(onStage: onStage));
  }

  /// Upload a sign request and wait for the person's answer. Returns the raw
  /// result; decode it with the chain's parser ([SolanaSignResult]).
  Future<Uint8List> sign({
    required int chain,
    required List<DerivationPath> keys,
    required List<int> tx,
    void Function(int stage)? onStage,
  }) async {
    final blob = encodeSignBlob(chain: chain, keys: keys, tx: tx);
    final begin = await call(
      Opcode.hostSignBegin,
      (ByteWriter()
            ..u8(chain)
            ..u32(blob.length))
          .toBytes(),
    );
    switch (begin.status) {
      case Status.ok:
        break;
      case Status.notNow:
        throw CatCardNotNow(
          BusyReason.describe(begin.detail),
          detail: begin.detail,
        );
      case Status.refused:
        throw CatCardRefused(begin.text);
      default:
        throw CatCardProtocolException(
          'HostSignBegin: ${Status.name(begin.status)}',
        );
    }
    var chunk = hostWalletDataMax;
    if (begin.body.length >= 4) {
      final announced = ByteReader(begin.body).u32();
      if (announced > 0 && announced < chunk) chunk = announced;
    }
    Reply commit;
    try {
      var at = 0;
      while (at < blob.length) {
        final end = at + chunk < blob.length ? at + chunk : blob.length;
        final r = await call(
          Opcode.hostSignData,
          (ByteWriter()
                ..u32(at)
                ..bytes(Uint8List.sublistView(blob, at, end)))
              .toBytes(),
        );
        if (!r.ok) {
          throw CatCardProtocolException(
            'HostSignData at $at: ${Status.name(r.status)}',
          );
        }
        at = end;
      }
      commit = await call(Opcode.hostSignCommit, Uint8List(0));
    } catch (_) {
      await abort();
      rethrow;
    }
    switch (commit.status) {
      case Status.ok:
        break;
      case Status.refused:
        throw CatCardRefused(commit.text);
      default:
        throw CatCardProtocolException(
          'HostSignCommit: ${Status.name(commit.status)}',
        );
    }
    return awaitResult(onStage: onStage);
  }

  /// Poll `HostResult` until the person has answered, then page the result in.
  Future<Uint8List> awaitResult({void Function(int stage)? onStage}) async {
    final deadline = DateTime.now().add(patience);
    int? said;
    while (true) {
      final r = await call(Opcode.hostResult, u32le(0));
      if (r.status == Status.notNow) {
        final stage = r.detail;
        if (stage != said) {
          said = stage;
          onStage?.call(stage);
        }
        if (stage == ResultStage.nothing || stage == ResultStage.otherSession) {
          throw CatCardNotNow(ResultStage.describe(stage), detail: stage);
        }
        if (DateTime.now().isAfter(deadline)) {
          throw CatCardException('nobody answered at the device');
        }
        await Future<void>.delayed(pollInterval);
        continue;
      }
      if (r.status == Status.declined) throw CatCardDeclined();
      if (r.status == Status.refused) throw CatCardRefused(r.text);
      if (!r.ok) {
        throw CatCardProtocolException('HostResult: ${Status.name(r.status)}');
      }
      final first = ByteReader(r.body);
      final total = first.u32();
      final got = BytesBuilder(copy: false)..add(first.rest());
      while (got.length < total) {
        final page = await call(Opcode.hostResult, u32le(got.length));
        if (!page.ok) {
          throw CatCardProtocolException(
            'HostResult page: ${Status.name(page.status)}',
          );
        }
        final pr = ByteReader(page.body);
        pr.u32();
        final bytes = pr.rest();
        if (bytes.isEmpty) {
          throw CatCardProtocolException('empty result page before the end');
        }
        got.add(bytes);
      }
      final out = got.toBytes();
      if (out.length != total) {
        throw CatCardProtocolException('result overran its total');
      }
      return out;
    }
  }

  /// Drop an upload that was not committed, or a result that will not be
  /// fetched. Cannot withdraw a question already on the screen.
  Future<void> abort() async {
    try {
      await call(Opcode.hostAbort, Uint8List(0));
    } catch (_) {
      // Best effort: the session may already be gone.
    }
  }
}
