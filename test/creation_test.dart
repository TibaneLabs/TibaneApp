import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet/creation.dart';

/// Phase 2 (Atonline-parity) — pure creation-committee decisions (§5.2 / D5).
/// The biometric enrollment prompt, keygen, and at-rest writes are
/// device-verified.
void main() {
  group('creationModeFor', () {
    test('biometric device → biometric committee', () {
      expect(
        creationModeFor(hasBiometric: true),
        CreationMode.biometric,
      );
    });

    test('no biometric → D5 password-only committee', () {
      expect(
        creationModeFor(hasBiometric: false),
        CreationMode.passwordOnly,
      );
    });

    test('forceUnsafe overrides a biometric device → password-only', () {
      expect(
        creationModeFor(hasBiometric: true, forceUnsafe: true),
        CreationMode.passwordOnly,
      );
    });
  });

  group('creationKeyTypes', () {
    test('biometric → [StoreKey, RemoteKey, Password]', () {
      expect(
        creationKeyTypes(CreationMode.biometric),
        ['StoreKey', 'RemoteKey', 'Password'],
      );
    });

    test('D5 → [Password, Password, RemoteKey] (two password shares)', () {
      expect(
        creationKeyTypes(CreationMode.passwordOnly),
        ['Password', 'Password', 'RemoteKey'],
      );
    });

    test('both committees have ≥3 keys (multiCreate floor)', () {
      for (final mode in CreationMode.values) {
        expect(creationKeyTypes(mode).length, greaterThanOrEqualTo(3));
      }
    });
  });

  group('modeHasStoreKey', () {
    test('biometric wallet has a StoreKey; D5 does not', () {
      expect(modeHasStoreKey(CreationMode.biometric), isTrue);
      expect(modeHasStoreKey(CreationMode.passwordOnly), isFalse);
    });
  });
}
