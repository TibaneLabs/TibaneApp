import 'dart:async';

import 'package:biometric_storage/biometric_storage.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/normal_wallet_biometrics.dart';

Wallet normalBiometricWallet({
  String id = 'seed-solana',
  String protocol = 'mnemonic',
  int threshold = 0,
  int generation = 0,
  List<String> types = const ['Password'],
}) => Wallet(
  id: id,
  name: 'Fixture wallet',
  curve: 'ed25519',
  protocol: protocol,
  threshold: threshold,
  gen: generation,
  pubkey: 'wallet-public-$id',
  chaincode: '',
  created: DateTime.utc(2026),
  modified: DateTime.utc(2026),
  keys: [
    for (final (i, type) in types.indexed)
      WalletKey(
        id: '$id-$type-$i',
        wallet: id,
        type: type,
        gen: generation,
        key: 'key-public-$id',
      ),
  ],
);

class FakeNormalBiometricVault implements NormalBiometricVault {
  final values = <String, String>{};
  int reads = 0;
  int writes = 0;
  int ownerChecks = 0;
  int? failWrite;
  bool cancelRead = false;
  bool ownerApproved = true;
  Completer<String?>? pendingRead;
  Completer<NormalBiometricKind>? pendingAvailability;
  NormalBiometricKind kind = NormalBiometricKind.face;

  @override
  Future<NormalBiometricKind> availability() async =>
      pendingAvailability == null ? kind : await pendingAvailability!.future;
  @override
  Future<String?> read(String name, NormalBiometricPrompt prompt) async {
    reads++;
    if (cancelRead) {
      throw AuthException(AuthExceptionCode.userCanceled, 'Fixture canceled');
    }
    if (pendingRead != null) return pendingRead!.future;
    return values[name];
  }

  @override
  Future<void> write(
    String name,
    String secret,
    NormalBiometricPrompt prompt,
  ) async {
    writes++;
    if (writes == failWrite) throw const NormalBiometricUnavailable();
    values[name] = secret;
  }

  @override
  Future<void> delete(String name) async {
    values.remove(name);
  }

  @override
  Future<bool> confirmOwner(String reason) async {
    ownerChecks++;
    return ownerApproved;
  }
}

const normalBiometricPrompt = NormalBiometricPrompt(
  'Fixture authorization',
  'Cancel',
);
