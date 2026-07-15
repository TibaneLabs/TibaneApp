import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/screens/wallet/wallet_details_screen.dart';

/// Unit tests for the wallet-rename validator. libwallet imposes no naming
/// convention (the name is an untrusted display string), so
/// `WalletDetailsScreen.validateWalletName` enforces the app-side rule: trim
/// surrounding whitespace, then require 3–28 characters. The dialog render
/// itself needs the real theme/WalletService, so it's verified on-device.
void main() {
  group('WalletDetailsScreen.validateWalletName', () {
    test('rejects names shorter than the minimum', () {
      final r = WalletDetailsScreen.validateWalletName('ab');
      expect(r.name, isNull);
      expect(r.errorCode, isNotNull);
    });

    test('accepts a name at exactly the minimum length', () {
      final r = WalletDetailsScreen.validateWalletName('abc');
      expect(r.name, 'abc');
      expect(r.errorCode, isNull);
    });

    test('trims leading/trailing whitespace before validating', () {
      final r = WalletDetailsScreen.validateWalletName('  My Wallet  ');
      expect(r.name, 'My Wallet');
      expect(r.errorCode, isNull);
    });

    test('rejects when only whitespace padding pads the length', () {
      final r = WalletDetailsScreen.validateWalletName('  a  ');
      expect(r.name, isNull);
      expect(r.errorCode, isNotNull);
    });

    test('rejects an all-whitespace name', () {
      final r = WalletDetailsScreen.validateWalletName('        ');
      expect(r.name, isNull);
      expect(r.errorCode, isNotNull);
    });

    test('accepts a name at exactly the maximum length', () {
      final name = 'a' * WalletDetailsScreen.kNameMaxLength;
      final r = WalletDetailsScreen.validateWalletName(name);
      expect(r.name, name);
      expect(r.errorCode, isNull);
    });

    test('rejects a name one over the maximum length', () {
      final r = WalletDetailsScreen.validateWalletName(
        'a' * (WalletDetailsScreen.kNameMaxLength + 1),
      );
      expect(r.name, isNull);
      expect(r.errorCode, isNotNull);
    });

    test('measures length after trimming (padding around a max-length name)',
        () {
      final content = 'a' * WalletDetailsScreen.kNameMaxLength;
      final r = WalletDetailsScreen.validateWalletName('   $content   ');
      expect(r.name, content);
      expect(r.errorCode, isNull);
    });

    test('preserves internal whitespace', () {
      final r = WalletDetailsScreen.validateWalletName('My  Cool  Wallet');
      expect(r.name, 'My  Cool  Wallet');
      expect(r.errorCode, isNull);
    });
  });
}
