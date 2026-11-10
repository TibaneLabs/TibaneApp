import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/normal_wallet_biometrics.dart';

import 'helpers/normal_biometrics_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('full reset clears only normal-wallet biometric credentials', () async {
    final vault = FakeNormalBiometricVault();
    final auth = NormalWalletBiometrics(vault: vault);
    final sol = normalBiometricWallet();
    final eth = normalBiometricWallet(id: 'seed-ethereum');
    await auth.enable({sol: 'fixture', eth: 'fixture'}, normalBiometricPrompt);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('locale', 'pt');
    vault.values['unrelated-mpc-entry'] = 'unrelated-fixture';
    await auth.clear();
    expect(await auth.isEnabled(sol), isFalse);
    expect(await auth.isEnabled(eth), isFalse);
    expect(prefs.getString('locale'), 'pt');
    expect(vault.values.keys, ['unrelated-mpc-entry']);
  });

  test('only ordinary seed and single-device private-key wallets qualify', () {
    expect(supportsNormalWalletBiometrics(normalBiometricWallet()), isTrue);
    expect(
      supportsNormalWalletBiometrics(
        normalBiometricWallet(protocol: 'frost', types: ['StoreKey']),
      ),
      isTrue,
    );
    for (final types in [
      ['StoreKey', 'Password', 'RemoteKey'],
      ['Password', 'Password', 'RemoteKey'],
    ]) {
      expect(
        supportsNormalWalletBiometrics(
          normalBiometricWallet(protocol: 'frost', threshold: 1, types: types),
        ),
        isFalse,
      );
    }
    expect(
      supportsNormalWalletBiometrics(
        normalBiometricWallet(protocol: 'mnemonic', types: ['StoreKey']),
      ),
      isFalse,
    );
  });

  test('disabled by default and never reads a secret before opt-in', () async {
    final vault = FakeNormalBiometricVault();
    final auth = NormalWalletBiometrics(vault: vault);
    final wallet = normalBiometricWallet();
    expect(await auth.isEnabled(wallet), isFalse);
    expect(await auth.readSigningKey(wallet, normalBiometricPrompt), isNull);
    expect(vault.reads, 0);
  });

  test(
    'seed credential is gated on every read and never stored in preferences',
    () async {
      final vault = FakeNormalBiometricVault();
      final auth = NormalWalletBiometrics(vault: vault);
      final wallet = normalBiometricWallet();
      await auth.enable({
        wallet: 'fixture-password-only',
      }, normalBiometricPrompt);
      final first = await auth.readSigningKey(wallet, normalBiometricPrompt);
      final second = await auth.readSigningKey(wallet, normalBiometricPrompt);
      expect(first!.id, wallet.keys.single.id);
      expect(first.type, 'Password');
      expect(first.key, 'fixture-password-only');
      expect(second!.key, first.key);
      expect(vault.reads, 3); // enrollment verification, then each operation
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), hasLength(1));
      expect(
        prefs.getKeys().map(prefs.get).join(),
        isNot(contains('fixture-password-only')),
      );
      expect(vault.values.keys.single, startsWith('normal_signing_'));
    },
  );

  test(
    'private-key imports return the exact single StoreKey identifier',
    () async {
      final auth = NormalWalletBiometrics(vault: FakeNormalBiometricVault());
      final wallet = normalBiometricWallet(
        protocol: 'frost',
        types: ['StoreKey'],
      );
      await auth.enable({
        wallet: 'fixture-store-secret',
      }, normalBiometricPrompt);
      final key = await auth.readSigningKey(wallet, normalBiometricPrompt);
      expect(key!.type, 'StoreKey');
      expect(key.id, wallet.keys.single.id);
    },
  );

  test(
    'wallet and key-generation boundaries prevent credential reuse',
    () async {
      final auth = NormalWalletBiometrics(vault: FakeNormalBiometricVault());
      final wallet = normalBiometricWallet();
      await auth.enable({wallet: 'fixture'}, normalBiometricPrompt);
      expect(await auth.isEnabled(normalBiometricWallet(id: 'other')), isFalse);
      expect(
        await auth.isEnabled(normalBiometricWallet(generation: 1)),
        isFalse,
      );
      final mpc = normalBiometricWallet(
        protocol: 'frost',
        threshold: 1,
        types: ['StoreKey', 'Password', 'RemoteKey'],
      );
      expect(await auth.isEnabled(mpc), isFalse);
      expect(await auth.readSigningKey(mpc, normalBiometricPrompt), isNull);
      await expectLater(
        auth.enable({mpc: 'fixture'}, normalBiometricPrompt),
        throwsA(isA<NormalBiometricUnavailable>()),
      );
    },
  );

  test('cancelled enrollment rolls back both secret and opt-in', () async {
    final vault = FakeNormalBiometricVault()..cancelRead = true;
    final auth = NormalWalletBiometrics(vault: vault);
    final wallet = normalBiometricWallet();
    await expectLater(
      auth.enable({wallet: 'fixture'}, normalBiometricPrompt),
      throwsA(anything),
    );
    expect(await auth.isEnabled(wallet), isFalse);
    expect(vault.values, isEmpty);
  });

  test(
    'failed second-curve enrollment rolls back the whole new group',
    () async {
      final vault = FakeNormalBiometricVault()..failWrite = 2;
      final auth = NormalWalletBiometrics(vault: vault);
      final sol = normalBiometricWallet();
      final eth = normalBiometricWallet(id: 'seed-ethereum');
      await expectLater(
        auth.enable({sol: 'fixture', eth: 'fixture'}, normalBiometricPrompt),
        throwsA(isA<NormalBiometricUnavailable>()),
      );
      expect(await auth.isEnabled(sol), isFalse);
      expect(await auth.isEnabled(eth), isFalse);
      expect(vault.values, isEmpty);
    },
  );

  test('unavailable biometrics never saves a credential', () async {
    final vault = FakeNormalBiometricVault()
      ..kind = NormalBiometricKind.unavailable;
    final auth = NormalWalletBiometrics(vault: vault);
    await expectLater(
      auth.enable({normalBiometricWallet(): 'fixture'}, normalBiometricPrompt),
      throwsA(isA<NormalBiometricUnavailable>()),
    );
    expect(vault.writes, 0);
  });

  test(
    'disable requires device-owner approval and erases protected credentials',
    () async {
      final vault = FakeNormalBiometricVault();
      final auth = NormalWalletBiometrics(vault: vault);
      final wallet = normalBiometricWallet();
      await auth.enable({wallet: 'fixture'}, normalBiometricPrompt);
      vault.ownerApproved = false;
      expect(await auth.disable([wallet.id], 'Fixture disable'), isFalse);
      expect(await auth.isEnabled(wallet), isTrue);
      vault.ownerApproved = true;
      expect(await auth.disable([wallet.id], 'Fixture disable'), isTrue);
      expect(await auth.isEnabled(wallet), isFalse);
      expect(vault.values, isEmpty);
      expect(vault.ownerChecks, 2);
    },
  );

  test('wallet deletion cancels an in-flight biometric read', () async {
    final vault = FakeNormalBiometricVault();
    final auth = NormalWalletBiometrics(vault: vault);
    final wallet = normalBiometricWallet();
    await auth.enable({wallet: 'fixture'}, normalBiometricPrompt);
    vault.pendingRead = Completer<String?>();
    final pending = auth.readSigningKey(wallet, normalBiometricPrompt);
    await Future<void>.delayed(Duration.zero);
    await auth.forget([wallet.id]);
    vault.pendingRead!.complete('fixture');
    expect(await pending, isNull);
  });

  test(
    'deletion during availability check cannot re-enable a removed wallet',
    () async {
      final vault = FakeNormalBiometricVault()
        ..pendingAvailability = Completer<NormalBiometricKind>();
      final auth = NormalWalletBiometrics(vault: vault);
      final wallet = normalBiometricWallet();
      final pending = auth.enable({wallet: 'fixture'}, normalBiometricPrompt);
      final expectation = expectLater(
        pending,
        throwsA(isA<NormalBiometricUnavailable>()),
      );
      await auth.forget([wallet.id]);
      vault.pendingAvailability!.complete(NormalBiometricKind.face);
      await expectation;
      expect(vault.writes, 0);
      expect(await auth.isEnabled(wallet), isFalse);
    },
  );

  test(
    'restored preferences without this-device secret cannot produce a key',
    () async {
      final vault = FakeNormalBiometricVault();
      final auth = NormalWalletBiometrics(vault: vault);
      final wallet = normalBiometricWallet();
      await auth.enable({wallet: 'fixture'}, normalBiometricPrompt);
      vault.values.clear();
      expect(await auth.readSigningKey(wallet, normalBiometricPrompt), isNull);
    },
  );
}
