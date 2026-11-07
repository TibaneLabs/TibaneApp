import 'package:libwallet/libwallet.dart';

/// Migrate the seed's first standard account, not its master public key.
/// The source is removed only after address validation and local key custody.
Future<Wallet> importMnemonicAsMpc({
  required LibwalletClient client,
  required String mnemonic,
  required String passphrase,
  required String curve,
  required String name,
  required String password,
  required List<KeyDescription> newKeys,
  required Future<bool> Function(Wallet wallet) persistDeviceShare,
  required Future<void> Function(Wallet wallet) rollbackDeviceShare,
}) async {
  final type = switch (curve) {
    'ed25519' => 'solana',
    'secp256k1' => 'ethereum',
    _ => throw ArgumentError.value(curve, 'curve'),
  };
  final existingIds = (await client.wallets.list()).map((w) => w.id).toSet();
  Account? previousAccount;
  try {
    previousAccount = await client.accounts.getCurrent();
  } on LibwalletException {
    // A fresh installation has no selected account yet.
  }
  Wallet? source;
  var migrated = <Wallet>[];
  var complete = false;
  try {
    final unlock = [KeyDescription.password(password)];
    source = await client.wallets.importMnemonic(
      mnemonic: mnemonic,
      passphrase: passphrase,
      curve: curve,
      name: name,
      keys: unlock,
    );
    if (existingIds.contains(source.id)) {
      throw StateError('Mnemonic import returned an existing wallet');
    }
    final original = await client.accounts.create(
      wallet: source.id,
      name: name,
      type: type,
      index: 0,
      keys: unlock.map((key) => key.toJson()).toList(),
    );
    if (original.path.isEmpty || original.address.isEmpty) {
      throw StateError('Mnemonic account has no derivation path or address');
    }
    migrated = await client.wallets.promoteMnemonic(
      source.id,
      oldKeys: unlock,
      chains: [
        ChainMigration(
          network: type,
          derivationPath: original.path,
          curve: curve,
          name: name,
        ),
      ],
      newKeys: newKeys,
      threshold: 1,
    );
    if (migrated.length != 1 ||
        migrated.single.curve != curve ||
        existingIds.contains(migrated.single.id) ||
        migrated.single.id == source.id) {
      throw StateError('Invalid mnemonic migration result');
    }
    final target = migrated.single;
    // promoteMnemonic creates a wallet, not its visible account. Account.list's
    // wallet filter is unreliable in 0.5.5, so create the target explicitly.
    final account = await client.accounts.create(
      wallet: target.id,
      name: name,
      type: type,
      index: 0,
    );
    final sameAddress =
        account.wallet == target.id &&
        account.type == type &&
        account.index == 0 &&
        (type == 'ethereum'
            ? account.address.toLowerCase() == original.address.toLowerCase()
            : account.address == original.address);
    if (!sameAddress) {
      throw StateError('imported_promotion_identity_changed');
    }
    if (!await persistDeviceShare(target)) {
      throw StateError('Could not persist the imported wallet key');
    }
    await client.wallets.delete(source.id);
    complete = true;
    return target;
  } finally {
    if (!complete) {
      // Never remove a wallet that was present before this operation.
      for (final wallet in migrated) {
        if (existingIds.contains(wallet.id) || wallet.id == source?.id) {
          continue;
        }
        try {
          await client.wallets.delete(wallet.id);
          await rollbackDeviceShare(wallet);
        } catch (_) {
          // Keep the original migration error; cleanup is best effort.
        }
      }
      if (source != null && !existingIds.contains(source.id)) {
        try {
          await client.wallets.delete(source.id);
        } catch (_) {}
      }
    }
    if (previousAccount != null) {
      try {
        await client.accounts.setCurrent(previousAccount.id);
      } catch (_) {}
    }
  }
}
