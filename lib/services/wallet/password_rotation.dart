import 'package:libwallet/libwallet.dart';

import 'signing.dart';

class PasswordRotationItem {
  PasswordRotationItem(
    this.wallet,
    this.oldKeys,
    this.storeSecret,
    this.alreadyUpdated,
  );
  final Wallet wallet;
  final List<KeyDescription> oldKeys;
  final String? storeSecret;
  final bool alreadyUpdated;

  List<KeyDescription> newKeys(String password, String remoteKey) => [
    for (final key in wallet.keys)
      if (key.isPassword)
        KeyDescription.password(password)
      else if (key.isStoreKey)
        KeyDescription.storeKey(key.key)
      else if (key.isRemoteKey)
        KeyDescription.remoteKey(remoteKey),
  ];
}

class PasswordRotationIncomplete implements Exception {
  PasswordRotationIncomplete(this.cause);
  final Object cause;
  @override
  String toString() => 'password_update_incomplete';
}

Future<List<PasswordRotationItem>> preparePasswordRotation({
  required List<Wallet> wallets,
  required String oldPassword,
  required String newPassword,
  required Future<bool> Function(Wallet, String) passwordMatches,
  required Future<String?> Function(Wallet, WalletKey, String) readStoreSecret,
}) async {
  final plans = <PasswordRotationItem>[];
  for (final wallet in wallets) {
    if (wallet.keys.length < 2 ||
        !wallet.keys.any((k) => k.isPassword) ||
        wallet.keys.any(
          (k) => !k.isPassword && !k.isStoreKey && !k.isRemoteKey,
        )) {
      throw StateError('Unsupported wallet password management model');
    }
    final updated = await passwordMatches(wallet, newPassword);
    if (!updated && !await passwordMatches(wallet, oldPassword)) {
      throw StateError('Wrong password');
    }
    final password = updated ? newPassword : oldPassword;
    final oldKeys = <KeyDescription>[];
    String? storeSecret;
    for (final key in wallet.keys) {
      if (key.isStoreKey) {
        storeSecret =
            await readStoreSecret(wallet, key, oldPassword) ??
            await readStoreSecret(wallet, key, newPassword);
        if (storeSecret == null) {
          throw StateError(
            'Device share unavailable; recover this device first',
          );
        }
        oldKeys.add(
          KeyDescription(type: 'StoreKey', id: key.id, key: storeSecret),
        );
      } else if (key.isPassword) {
        oldKeys.add(
          KeyDescription(type: 'Password', id: key.id, key: password),
        );
      }
    }
    if (oldKeys.length < requiredSigningShares(wallet.threshold)) {
      throw StateError('Not enough local shares for password management');
    }
    plans.add(
      PasswordRotationItem(
        wallet,
        oldKeys.take(requiredSigningShares(wallet.threshold)).toList(),
        storeSecret,
        updated,
      ),
    );
  }
  // Native secp256k1 capability failures should occur before mutating Solana.
  plans.sort(
    (a, b) => (a.wallet.curve == 'secp256k1' ? 0 : 1).compareTo(
      b.wallet.curve == 'secp256k1' ? 0 : 1,
    ),
  );
  return plans;
}

Future<void> executePasswordRotation({
  required List<PasswordRotationItem> plans,
  required String newPassword,
  required String remoteKey,
  required Future<Wallet> Function(PasswordRotationItem, List<KeyDescription>)
  reshare,
  required Future<void> Function(Wallet, String?) persist,
  required Future<void> Function(Set<String>) journal,
}) async {
  final remaining = plans.map((p) => p.wallet.id).toSet();
  await journal(remaining);
  var mutated = false;
  try {
    for (final plan in plans) {
      final after = plan.alreadyUpdated
          ? plan.wallet
          : await reshare(plan, plan.newKeys(newPassword, remoteKey));
      mutated = mutated || !plan.alreadyUpdated;
      if (after.pubkey != plan.wallet.pubkey ||
          after.curve != plan.wallet.curve) {
        throw StateError('Password rotation changed wallet identity');
      }
      await persist(after, plan.storeSecret);
      remaining.remove(plan.wallet.id);
      await journal(remaining);
    }
  } catch (error) {
    if (mutated || plans.any((p) => p.alreadyUpdated)) {
      throw PasswordRotationIncomplete(error);
    }
    rethrow;
  }
}
