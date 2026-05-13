import 'package:flutter/foundation.dart';

/// Interface every wallet implementation fulfills. `WalletService` owns the
/// active backend and forwards calls; screens never talk to backends directly.
abstract class WalletBackend extends ChangeNotifier {
  /// Stable identifier: `mwa` or `inapp`.
  String get id;

  String? get publicKey;
  String? get walletName;
  bool get isConnected;
  bool get isConnecting;
  String? get error;

  /// Best-effort restore from persistent state. Safe to call when nothing is saved.
  Future<void> tryRestore();

  /// Tear down any session state; clears persisted data for this backend.
  Future<void> disconnect();

  /// Sign `message` and return the raw ed25519 signature, or null on failure.
  Future<Uint8List?> signMessage(Uint8List message);

  /// Sign each provided serialized tx, returning the signed bytes.
  /// Null entries indicate individual failures (user rejection, etc).
  Future<List<Uint8List?>> signTransactions(List<Uint8List> transactions);

  /// Sign + broadcast each tx, returning the base58 signature or null.
  Future<List<String?>> signAndSendTransactions(List<Uint8List> transactions);

  /// Clear any error state.
  void clearError();
}
