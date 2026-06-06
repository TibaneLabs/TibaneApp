import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/secure_keystore.dart';

/// These tests run without a platform, so `flutter_secure_storage` is
/// unavailable and `isSecureStorageUsable()` is false — the keystore
/// exercises its **password-encrypted SharedPreferences fallback blob**
/// path. That's the copy that survives an iOS restore-from-iCloud-Backup
/// and the one the migration moves, so it's the security-critical path to
/// cover here. The OS-keystore path needs an on-device/integration test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Start every test from empty prefs. `clear()` on the cached instance is
  // robust against shared_preferences' instance caching across tests.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  group('per-wallet device share', () {
    test('round-trips a device share keyed by walletId', () async {
      final ks = SecureKeystore();
      await ks.writeDeviceShare(
        walletId: 'wlt-A',
        value: 'shareA',
        password: 'pw',
      );
      expect(
        await ks.readDeviceShare(walletId: 'wlt-A', password: 'pw'),
        'shareA',
      );
      expect(await ks.hasDeviceShare('wlt-A'), isTrue);
    });

    test('wallets are isolated — one never sees another', () async {
      final ks = SecureKeystore();
      await ks.writeDeviceShare(
        walletId: 'wlt-A',
        value: 'shareA',
        password: 'pwA',
      );
      await ks.writeDeviceShare(
        walletId: 'wlt-B',
        value: 'shareB',
        password: 'pwB',
      );
      expect(
        await ks.readDeviceShare(walletId: 'wlt-A', password: 'pwA'),
        'shareA',
      );
      expect(
        await ks.readDeviceShare(walletId: 'wlt-B', password: 'pwB'),
        'shareB',
      );
      expect(await ks.hasDeviceShare('wlt-C'), isFalse);
      expect(
        await ks.readDeviceShare(walletId: 'wlt-C', password: 'pw'),
        isNull,
      );
    });

    test('wrong password throws WrongPasswordException', () async {
      final ks = SecureKeystore();
      await ks.writeDeviceShare(
        walletId: 'wlt-A',
        value: 'shareA',
        password: 'right',
      );
      expect(
        () => ks.readDeviceShare(walletId: 'wlt-A', password: 'wrong'),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('delete removes only the targeted wallet', () async {
      final ks = SecureKeystore();
      await ks.writeDeviceShare(walletId: 'wlt-A', value: 'a', password: 'pw');
      await ks.writeDeviceShare(walletId: 'wlt-B', value: 'b', password: 'pw');
      await ks.deleteDeviceShare('wlt-A');
      expect(await ks.hasDeviceShare('wlt-A'), isFalse);
      expect(await ks.hasDeviceShare('wlt-B'), isTrue);
    });
  });

  group('migration v1 (single-slot) -> v2 (per-wallet)', () {
    test('moves the legacy blob to the active wallet, then deletes legacy',
        () async {
      final ks = SecureKeystore();
      final prefs = await SharedPreferences.getInstance();

      // Produce a real encrypted blob, then arrange it as the legacy
      // single-slot entry for the active wallet.
      await ks.writeDeviceShare(walletId: 'tmp', value: 'legacy', password: 'pw');
      final blob = prefs.getString('libw_device_share_blob_v1_tmp')!;
      await prefs.remove('libw_device_share_blob_v1_tmp');
      await prefs.setString('libw_device_share_blob_v1', blob);
      await prefs.setString('libw_wallet_id', 'wlt-A');

      await ks.migrateToPerWalletV2('wlt-A');

      expect(prefs.getString('libw_device_share_blob_v1'), isNull,
          reason: 'legacy entry deleted after verified copy');
      expect(prefs.getString('libw_device_share_blob_v1_wlt-A'), blob,
          reason: 'copied to the active wallet key');
      expect(prefs.getBool('libw_schema_v2'), isTrue);
      expect(
        await ks.readDeviceShare(walletId: 'wlt-A', password: 'pw'),
        'legacy',
        reason: 'migrated share still decrypts',
      );
    });

    test('is idempotent and never re-touches legacy once v2 is set', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('libw_device_share_blob_v1', 'X');
      await prefs.setString('libw_wallet_id', 'wlt-A');
      final ks = SecureKeystore();

      await ks.migrateToPerWalletV2('wlt-A');
      expect(prefs.getBool('libw_schema_v2'), isTrue);
      expect(prefs.getString('libw_device_share_blob_v1_wlt-A'), 'X');
      expect(prefs.getString('libw_device_share_blob_v1'), isNull);

      // A stray legacy entry appearing after v2 must be left untouched.
      await prefs.setString('libw_device_share_blob_v1', 'Y');
      await ks.migrateToPerWalletV2('wlt-A');
      expect(prefs.getString('libw_device_share_blob_v1'), 'Y');
    });

    test('fresh install (no active wallet) just sets the flag', () async {
      final ks = SecureKeystore();
      await ks.migrateToPerWalletV2(null);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('libw_schema_v2'), isTrue);
    });

    test('readDeviceShare falls back to the legacy blob before migration',
        () async {
      final ks = SecureKeystore();
      final prefs = await SharedPreferences.getInstance();
      // Real blob for the active wallet, parked under the legacy key, no v2.
      await ks.writeDeviceShare(walletId: 'tmp', value: 'pre', password: 'pw');
      final blob = prefs.getString('libw_device_share_blob_v1_tmp')!;
      await prefs.remove('libw_device_share_blob_v1_tmp');
      await prefs.setString('libw_device_share_blob_v1', blob);

      // No per-wallet entry for wlt-A yet, but the legacy fallback resolves it.
      expect(
        await ks.readDeviceShare(walletId: 'wlt-A', password: 'pw'),
        'pre',
      );
    });
  });
}
