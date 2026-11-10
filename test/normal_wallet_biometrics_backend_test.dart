import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/normal_wallet_biometrics.dart';
import 'package:tibaneapp/services/wallet/wallet_group_store.dart';

import 'helpers/normal_biometrics_fixtures.dart';

class _Wallets implements WalletApi {
  _Wallets(this.values);
  final List<Wallet> values;
  @override
  Future<List<Wallet>> list() async => values;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StoreKeys implements StoreKeyApi {
  int checks = 0;
  @override
  Future<String> derivePassword({
    required String password,
    required String walletKeyId,
  }) async {
    checks++;
    return password == 'correct-fixture'
        ? 'key-public-${walletKeyId.replaceFirst('-Password-0', '')}'
        : 'different-public-key';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  _Client(List<Wallet> values) : wallets = _Wallets(values);
  @override
  final _Wallets wallets;
  @override
  final _StoreKeys storeKeys = _StoreKeys();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(_Client client, NormalWalletBiometrics auth, this.selected)
    : super(client: client, normalBiometrics: auth);
  String selected;
  @override
  String get walletId => selected;
  @override
  Future<String?> readStoreKeyPrivateForWallet(
    String walletId,
    WalletKey storeKey, {
    String? password,
  }) async => 'fixture-device-secret';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'enrollment verifies the actual Password public key before saving',
    () async {
      final wallet = normalBiometricWallet();
      final client = _Client([wallet]);
      final vault = FakeNormalBiometricVault();
      final auth = NormalWalletBiometrics(vault: vault);
      final backend = _Backend(client, auth, wallet.id);
      addTearDown(backend.dispose);
      await expectLater(
        backend.enableNormalWalletBiometrics(
          password: 'wrong-fixture',
          prompt: normalBiometricPrompt,
        ),
        throwsStateError,
      );
      expect(vault.writes, 0);
      expect(await auth.isEnabled(wallet), isFalse);
      await backend.enableNormalWalletBiometrics(
        password: 'correct-fixture',
        prompt: normalBiometricPrompt,
      );
      expect(client.storeKeys.checks, 2);
      expect(await auth.isEnabled(wallet), isTrue);
    },
  );

  test(
    'one seed enrollment covers both curve wallets, not other wallets or imported children',
    () async {
      final sol = normalBiometricWallet();
      final eth = normalBiometricWallet(id: 'seed-ethereum');
      final other = normalBiometricWallet(id: 'unrelated');
      final child = normalBiometricWallet(
        id: 'imported-child',
        protocol: 'frost',
        types: ['StoreKey'],
      );
      final mpc = normalBiometricWallet(
        id: 'mpc',
        protocol: 'frost',
        threshold: 1,
        types: ['StoreKey', 'Password', 'RemoteKey'],
      );
      await WalletGroupStore.associate([sol.id, eth.id, child.id]);
      final client = _Client([sol, eth, child, mpc, other]);
      final auth = NormalWalletBiometrics(vault: FakeNormalBiometricVault());
      final backend = _Backend(client, auth, sol.id);
      addTearDown(backend.dispose);
      expect((await backend.normalBiometricWallets()).map((w) => w.id), [
        sol.id,
        eth.id,
      ]);
      await backend.enableNormalWalletBiometrics(
        password: 'correct-fixture',
        prompt: normalBiometricPrompt,
      );
      expect(await auth.isEnabled(sol), isTrue);
      expect(await auth.isEnabled(eth), isTrue);
      expect(await auth.isEnabled(other), isFalse);
      expect(await auth.isEnabled(child), isFalse);
      expect(await auth.isEnabled(mpc), isFalse);
      backend.selected = eth.id;
      expect(
        await backend.disableNormalWalletBiometrics('Fixture disable'),
        isTrue,
      );
      expect(await auth.isEnabled(sol), isFalse);
      expect(await auth.isEnabled(eth), isFalse);
    },
  );

  test(
    'MPC can never enroll a Password or device share through this feature',
    () async {
      final wallet = normalBiometricWallet(
        protocol: 'frost',
        threshold: 1,
        types: ['StoreKey', 'Password', 'RemoteKey'],
      );
      final vault = FakeNormalBiometricVault();
      final backend = _Backend(
        _Client([wallet]),
        NormalWalletBiometrics(vault: vault),
        wallet.id,
      );
      addTearDown(backend.dispose);
      await expectLater(
        backend.enableNormalWalletBiometrics(
          password: 'correct-fixture',
          prompt: normalBiometricPrompt,
        ),
        throwsA(isA<NormalBiometricUnavailable>()),
      );
      expect(vault.writes, 0);
    },
  );

  test(
    'a private-key import enrolls just its own device credential without inventing a password',
    () async {
      final wallet = normalBiometricWallet(
        protocol: 'frost',
        types: ['StoreKey'],
      );
      final client = _Client([wallet]);
      final auth = NormalWalletBiometrics(vault: FakeNormalBiometricVault());
      final backend = _Backend(client, auth, wallet.id);
      addTearDown(backend.dispose);
      await backend.enableNormalWalletBiometrics(prompt: normalBiometricPrompt);
      expect(client.storeKeys.checks, 0);
      final key = await auth.readSigningKey(wallet, normalBiometricPrompt);
      expect(key!.key, 'fixture-device-secret');
      expect(key.type, 'StoreKey');
    },
  );
}
