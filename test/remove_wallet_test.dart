import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/secure_keystore.dart';

/// Phase 8 unit tests. `removeWallet` itself needs the live client, so its
/// next-active selection is the pure [LibwalletBackend.pickNextActive], and
/// the per-wallet deletion is verified at the keystore layer (removing one
/// wallet's device share leaves the others' intact).
void main() {
  group('pickNextActive', () {
    test('returns the first remaining wallet that is not the removed one', () {
      expect(LibwalletBackend.pickNextActive(['A', 'B', 'C'], 'A'), 'B');
    });

    test('skips the removed id wherever it sits in the list', () {
      expect(LibwalletBackend.pickNextActive(['A', 'B'], 'B'), 'A');
    });

    test('returns null when only the removed wallet remains', () {
      expect(LibwalletBackend.pickNextActive(['A'], 'A'), isNull);
    });

    test('returns null for an empty list', () {
      expect(LibwalletBackend.pickNextActive(const [], 'A'), isNull);
    });

    test('returns the first when the removed id is not present', () {
      expect(LibwalletBackend.pickNextActive(['A', 'B'], 'C'), 'A');
    });

    test('skips every removed id when removing a logical wallet group', () {
      expect(
        LibwalletBackend.pickNextActiveAfterRemoving(
          ['A', 'B', 'C'],
          {'A', 'B'},
        ),
        'C',
      );
      expect(
        LibwalletBackend.pickNextActiveAfterRemoving(['A', 'B'], {'A', 'B'}),
        isNull,
      );
    });
  });

  group('removeWallet deletes only the targeted wallet share', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    });

    test('deleting wallet A leaves wallet B usable', () async {
      final ks = SecureKeystore();
      await ks.writeDeviceShare(walletId: 'A', value: 'shareA', password: 'pw');
      await ks.writeDeviceShare(walletId: 'B', value: 'shareB', password: 'pw');

      // removeWallet calls _keystore.deleteDeviceShare(walletId) for the
      // removed wallet only.
      await ks.deleteDeviceShare('A');

      expect(await ks.hasDeviceShare('A'), isFalse);
      expect(await ks.hasDeviceShare('B'), isTrue);
      expect(await ks.readDeviceShare(walletId: 'B', password: 'pw'), 'shareB');
    });
  });
}
