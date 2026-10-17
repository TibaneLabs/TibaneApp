import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rpc_service.dart';
import '../wallet/wallet_backend.dart';
import 'apdu.dart';
import 'client.dart';
import 'hostwallet.dart';
import 'platform_card.dart';
import 'wire.dart';

/// Shows [code] large and asks the person whether the CatCard shows the
/// same. Resolves true only when they tap "same code". Never pre-accept: the
/// comparison is the whole defence against a relay between phone and device.
typedef PairingCodeConfirmer = Future<bool> Function(String code);

/// Progress for a person: "Pairing…", "Review the transaction on the CatCard".
typedef CatCardStatusListener = void Function(String message);

/// A CatCard hardware wallet over USB as a [WalletBackend]: the phone builds
/// Solana transactions and the device signs them after showing them on its
/// own screen.
///
/// What persists is the account the person shared -- its address, key and
/// derivation path -- so the account shows in the switcher and its balances
/// load with the device unplugged. Nothing about the pairing persists: every
/// plug-in pairs afresh with a code compared on both screens, and every
/// session shares the account again before it may sign (the device remembers
/// shared accounts per session only).
class CatCardWalletBackend extends ChangeNotifier implements WalletBackend {
  static const _prefAddress = 'catcard_address';
  static const _prefPath = 'catcard_path';
  static const _prefPubkey = 'catcard_pubkey';
  static const _prefBoard = 'catcard_board';
  static const _prefAccount = 'catcard_account';
  static const _prefFingerprint = 'catcard_fingerprint';

  @override
  String get id => 'catcard';

  /// Set by the app: how the pairing code is shown and confirmed.
  PairingCodeConfirmer? codeConfirmer;

  /// Set by the app: where progress messages go.
  CatCardStatusListener? statusListener;

  /// How a card is opened; tests inject a fake.
  @visibleForTesting
  Future<ApduCard> Function({String? name}) openCard = PlatformApduCard.open;

  String? _address;
  DerivationPath? _path;
  Uint8List? _publicKeyBytes;
  String? _board;
  int? _account;
  String? _fingerprint;

  CatCardClient? _client;
  bool _sessionShared = false;
  bool _connecting = false;
  bool _busy = false;
  String? _error;

  @override
  String? get publicKey => _address;

  @override
  String? get walletName =>
      _board == null ? 'CatCard' : 'CatCard ${_board!.toUpperCase()}';

  /// An account has been shared and persisted; the device may be unplugged.
  @override
  bool get isConnected => _address != null;

  @override
  bool get isConnecting => _connecting;

  /// A paired USB session is open right now.
  bool get sessionOpen => _client?.paired ?? false;

  /// A sign or share is in progress on the device.
  bool get busy => _busy;

  @override
  String? get error => _error;

  /// The account number shared on the device (typed there; 0 by default).
  int? get account => _account;

  DerivationPath? get path => _path;
  Uint8List? get publicKeyBytes => _publicKeyBytes;
  String? get board => _board;
  String? get fingerprint => _fingerprint;

  @override
  Future<void> tryRestore() async {
    final prefs = await SharedPreferences.getInstance();
    final address = prefs.getString(_prefAddress);
    final path = prefs.getString(_prefPath);
    if (address == null || path == null) return;
    try {
      _path = DerivationPath.parse(path);
    } catch (_) {
      return;
    }
    _address = address;
    final pub = prefs.getString(_prefPubkey);
    _publicKeyBytes = pub == null ? null : bytesOfHex(pub);
    _board = prefs.getString(_prefBoard);
    _account = prefs.getInt(_prefAccount);
    _fingerprint = prefs.getString(_prefFingerprint);
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefAddress, _address!);
    await prefs.setString(_prefPath, _path!.text);
    if (_publicKeyBytes != null) {
      await prefs.setString(_prefPubkey, hexOf(_publicKeyBytes!));
    }
    if (_board != null) await prefs.setString(_prefBoard, _board!);
    if (_account != null) await prefs.setInt(_prefAccount, _account!);
    if (_fingerprint != null) {
      await prefs.setString(_prefFingerprint, _fingerprint!);
    }
  }

  /// Forget the shared account and end any session. The device keeps its
  /// keys; this only removes the account from the app.
  @override
  Future<void> disconnect() async {
    await endSession();
    _address = null;
    _path = null;
    _publicKeyBytes = null;
    _board = null;
    _account = null;
    _fingerprint = null;
    _error = null;
    final prefs = await SharedPreferences.getInstance();
    for (final k in [
      _prefAddress,
      _prefPath,
      _prefPubkey,
      _prefBoard,
      _prefAccount,
      _prefFingerprint,
    ]) {
      await prefs.remove(k);
    }
    notifyListeners();
  }

  /// End the USB session (the device was unplugged, or the person is done).
  /// The shared account stays.
  Future<void> endSession() async {
    final c = _client;
    _client = null;
    _sessionShared = false;
    if (c != null) await c.close();
  }

  /// Plug-in flow: open the reader, pair with the code compared on both
  /// screens, and have the person share an account. Adopts the Solana
  /// address it shares. Returns true on success; the reason is on [error]
  /// otherwise.
  Future<bool> connect() async {
    if (_connecting) return false;
    _connecting = true;
    _error = null;
    notifyListeners();
    try {
      final client = await _openAndPair();
      final reply = await _shareAddresses(client);
      final entry = _solanaEntry(reply);
      _address = entry.address;
      _path = entry.addressPath;
      _publicKeyBytes = entry.publicKey;
      _board = client.identity?.board;
      _account = reply.account;
      _fingerprint = hexOf(reply.fingerprint);
      await _persist();
      _status('CatCard account ${reply.account} connected.');
      return true;
    } on CatCardException catch (e) {
      _error = e.message;
      await endSession();
      return false;
    } catch (e) {
      _error = 'CatCard: $e';
      await endSession();
      return false;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  void _status(String message) {
    debugPrint('[catcard] $message');
    statusListener?.call(message);
  }

  /// A paired client: the open one, or a fresh open + identify + pair.
  Future<CatCardClient> _openAndPair() async {
    final existing = _client;
    if (existing != null && existing.paired) return existing;
    await endSession();
    _status('Looking for the CatCard…');
    final card = await openCard();
    final client = CatCardClient(ApduTransport(card));
    try {
      final identity = await client.identify();
      if (!identity.usable) {
        throw CatCardException(
          'This CatCard firmware (${identity.version}) does not offer the '
          'phone protocol. Update it with CatCard Manager.',
        );
      }
      if (!identity.unlocked) {
        throw CatCardNotNow(
          'Unlock the CatCard by entering its PIN, then try again.',
          detail: BusyReason.locked,
        );
      }
      if (identity.isBench) {
        _status('Warning: this CatCard runs a bench build with debug access.');
      }
      _status('Pairing with the CatCard…');
      final code = await client.beginPairing();
      final confirm = codeConfirmer;
      if (confirm == null) {
        await client.abortPairing();
        throw CatCardException('The app cannot show the pairing code here.');
      }
      final same = await confirm(code);
      if (!same) {
        await client.abortPairing();
        throw CatCardDeclined('Pairing cancelled: the codes were not confirmed.');
      }
      _status('Accept the pairing on the CatCard.');
      await client.confirmPairing(
        onWaitingForDevice: () =>
            _status('Waiting for you to accept on the CatCard…'),
      );
      _client = client;
      _sessionShared = false;
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  /// Ask the device to share addresses; the person picks the account there.
  Future<AddressesReply> _shareAddresses(CatCardClient client) async {
    final which = _account;
    _status(
      which == null
          ? 'On the CatCard, share this wallet\'s addresses and choose the account.'
          : 'On the CatCard, share addresses for account $which.',
    );
    final reply = await client.hostWallet.addresses(
      onStage: (stage) => _status(_stageText(stage)),
    );
    _sessionShared = true;
    return reply;
  }

  static String _stageText(int stage) => switch (stage) {
    ResultStage.queued => 'Waiting for the CatCard screen…',
    ResultStage.onScreen => 'Answer on the CatCard.',
    _ => ResultStage.describe(stage),
  };

  AddressEntry _solanaEntry(AddressesReply reply) {
    final sol = reply.solana.toList();
    if (sol.isEmpty) {
      throw CatCardException(
        'The CatCard shared no Solana address. It needs a multichain firmware '
        'and Solana ticked when sharing.',
      );
    }
    return sol.first;
  }

  /// A session that may sign for the persisted account: paired, with that
  /// account shared on it.
  Future<CatCardClient> _sessionForSigning() async {
    final client = await _openAndPair();
    if (!_sessionShared) {
      final reply = await _shareAddresses(client);
      final entry = _solanaEntry(reply);
      if (entry.address != _address) {
        throw CatCardException(
          'The CatCard shared account ${reply.account}, but this app account '
          'is account ${_account ?? '?'} ($_address). Share that one instead.',
        );
      }
    }
    return client;
  }

  @override
  Future<Uint8List?> signMessage(Uint8List message) async {
    _error =
        'A CatCard signs transactions only; signing messages is not available.';
    notifyListeners();
    return null;
  }

  @override
  Future<List<Uint8List?>> signTransactions(
    List<Uint8List> transactions,
  ) async {
    final path = _path;
    if (path == null) {
      _error = 'No CatCard account is connected.';
      notifyListeners();
      return List.filled(transactions.length, null);
    }
    if (_busy) {
      _error = 'The CatCard is busy with another request.';
      notifyListeners();
      return List.filled(transactions.length, null);
    }
    _busy = true;
    _error = null;
    notifyListeners();
    final out = <Uint8List?>[];
    try {
      final client = await _sessionForSigning();
      for (final tx in transactions) {
        try {
          _status('Review the transaction on the CatCard.');
          final raw = await client.hostWallet.sign(
            chain: ChainId.solana,
            keys: [path],
            tx: tx,
            onStage: (stage) => _status(_stageText(stage)),
          );
          out.add(SolanaSignResult.parse(raw).transaction);
        } on CatCardDeclined catch (e) {
          _error = e.message;
          out.add(null);
        } on CatCardRefused catch (e) {
          _error = 'The CatCard refused: ${e.message}';
          out.add(null);
        }
      }
    } on CatCardException catch (e) {
      _error = e.message;
      debugPrint('[catcard] sign failed: ${e.message}');
      await endSession();
    } catch (e) {
      _error = 'CatCard: $e';
      debugPrint('[catcard] sign failed: $e');
      await endSession();
    } finally {
      _busy = false;
      notifyListeners();
    }
    while (out.length < transactions.length) {
      out.add(null);
    }
    return out;
  }

  @override
  Future<List<String?>> signAndSendTransactions(
    List<Uint8List> transactions,
  ) async {
    final signed = await signTransactions(transactions);
    final rpc = RpcService();
    final out = <String?>[];
    for (final tx in signed) {
      if (tx == null) {
        out.add(null);
        continue;
      }
      try {
        out.add(await rpc.sendTransaction(tx));
      } catch (e) {
        _error = 'Broadcast failed: $e';
        debugPrint('[catcard] send failed: $e');
        out.add(null);
      }
    }
    notifyListeners();
    return out;
  }

  @override
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
