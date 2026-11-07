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
