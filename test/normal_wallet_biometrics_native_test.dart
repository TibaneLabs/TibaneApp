@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/normal_wallet_biometrics.dart';

import 'helpers/normal_biometrics_fixtures.dart';

class _Backend extends LibwalletBackend {
  _Backend(LibwalletClient client, NormalWalletBiometrics auth, this.selected)
    : super(client: client, normalBiometrics: auth);
  final String selected;
  @override
  String get walletId => selected;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final (curve, type) in [
    ('ed25519', 'solana'),
    ('secp256k1', 'ethereum'),
  ]) {
    test(
      'ordinary $type wallet signs and derives with a biometric-gated credential',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tibane-normal-biometrics-',
        );
        final binary =
            Directory(
              '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
            ).listSync().whereType<File>().singleWhere(
              (file) => file.path.endsWith('.dylib'),
            );
        final client = LibwalletClient.initialize(
          directory.path,
          library: DynamicLibrary.open(binary.path),
        );
        await client.ready;
        for (final network in await client.networks.list()) {
          await client.networks.update(network.id, rpc: 'http://127.0.0.1:9');
        }
        final vault = FakeNormalBiometricVault();
        final auth = NormalWalletBiometrics(vault: vault);
        // Public, unfunded BIP-39 fixture. No user wallet or remote 2FA is used.
        const phrase =
            'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        const password = 'biometric-native-fixture';
        final wallet = await client.wallets.importMnemonic(
          mnemonic: phrase,
          passphrase: '',
          curve: curve,
          name: 'Offline biometric fixture',
          keys: [KeyDescription.password(password)],
        );
        final backend = _Backend(client, auth, wallet.id);
        addTearDown(() async {
          backend.dispose();
          client.dispose();
          await directory.delete(recursive: true);
        });
        await expectLater(
          backend.enableNormalWalletBiometrics(
            password: 'wrong-fixture',
            prompt: normalBiometricPrompt,
          ),
          throwsStateError,
        );
        expect(vault.writes, 0);
        await backend.enableNormalWalletBiometrics(
          password: password,
          prompt: normalBiometricPrompt,
        );
        final unlocked = await auth.readSigningKey(
          wallet,
          normalBiometricPrompt,
        );
        expect(unlocked, isNotNull);
        for (var index = 0; index < 2; index++) {
          final account = await client.accounts.create(
            wallet: wallet.id,
            name: 'Offline account $index',
            type: type,
            index: index,
            keys: [unlocked!.toJson()],
          );
          final refreshedWallet = await client.wallets.get(wallet.id);
          expect(await auth.isEnabled(refreshedWallet), isTrue);
          final signingKey = await auth.readSigningKey(
            refreshedWallet,
            normalBiometricPrompt,
          );
          final signed = await client.accounts.signMessage(
            account.id,
            mode: type == 'solana' ? 'solana' : 'evm',
            message: Uint8List.fromList(
              'Offline biometric authorization test'.codeUnits,
            ),
            keys: [signingKey!.toJson()],
          );
          expect(signed.signature, isNotEmpty);
        }
        expect((await client.wallets.get(wallet.id)).pubkey, wallet.pubkey);
        expect(
          await backend.disableNormalWalletBiometrics('Fixture disable'),
          isTrue,
        );
        expect(vault.values, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
