@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';

void main() {
  test('libwallet derives the stored password public key', () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'tibane-password-verification-',
    );
    final client = LibwalletClient.initialize(
      dataDir.path,
      library: _openNativeLibrary(),
    );
    await client.ready;

    Wallet? wallet;
    await for (final event in client.wallets.create(
      name: 'Password verification',
      curve: 'ed25519',
      keys: const [
        KeyDescription(type: 'Password', key: 'correct-password'),
        KeyDescription(type: 'Password', key: 'second-password'),
        KeyDescription(type: 'Password', key: 'third-password'),
      ],
    )) {
      if (event case Complete(:final value)) wallet = value;
    }

    expect(wallet, isNotNull);
    final passwordKey = wallet!.keys.first;
    final correct = await client.storeKeys.derivePassword(
      password: 'correct-password',
      walletKeyId: passwordKey.id,
    );
    final incorrect = await client.storeKeys.derivePassword(
      password: 'incorrect-password',
      walletKeyId: passwordKey.id,
    );

    expect(correct, isNotEmpty);
    expect(correct, passwordKey.key);
    expect(incorrect, isNot(correct));

    // The check the app uses (libwallet >= 0.5.11): open the share itself.
    final ok = await client.walletKeys.verify(
      passwordKey.id,
      key: KeyDescription.password('correct-password'),
    );
    expect(ok.valid, isTrue);
    expect(ok.kdf, 'argon2id');
    expect(ok.needsKdfUpgrade, isFalse);
    final wrong = await client.walletKeys.verify(
      passwordKey.id,
      key: KeyDescription.password('incorrect-password'),
    );
    expect(wrong.valid, isFalse);
  });

  test('recovery lists a phrase\'s addresses offline and wipes it', () async {
    final dataDir = await Directory.systemTemp.createTemp('tibane-recovery-');
    final client = LibwalletClient.initialize(
      dataDir.path,
      library: _openNativeLibrary(),
    );
    await client.ready;
    final session = await client.recovery.open(
      RecoverySource.mnemonic(
        'abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon abandon abandon about',
      ),
    );
    final rows = await session.addresses(count: 1);
    final chains = rows.map((r) => r.chain).toSet();
    // Every chain the recovery screen maps to an account type.
    expect(
      chains,
      containsAll([
        'bitcoin',
        'litecoin',
        'dogecoin',
        'bitcoin-cash',
        'monacoin',
        'ethereum',
        'solana',
        'tron',
      ]),
    );
    final eth = rows.firstWhere(
      (r) => r.chain == 'ethereum' && r.path == "m/44'/60'/0'/0/0",
    );
    expect(
      eth.address.toLowerCase(),
      '0x9858effd232b4033e47d90003d41ec34ecaeda94',
    );
    expect(session.layouts.any((l) => !l.standard), isTrue);
    await session.close();
    await expectLater(session.addresses(count: 1), throwsA(anything));
  });
}

DynamicLibrary _openNativeLibrary() {
  final nativeBuildDir = Directory(
    '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
  );
  final nativeBinary = nativeBuildDir.listSync().whereType<File>().singleWhere(
    (file) => file.path.endsWith('.dylib'),
  );
  return DynamicLibrary.open(nativeBinary.path);
}
