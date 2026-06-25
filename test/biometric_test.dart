import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:tibaneapp/services/wallet/biometric.dart';

/// Phase 0 (Atonline-parity migration) — biometric availability decision.
///
/// Only the pure decision is unit-tested here. The `setSecuredKey` /
/// `askSecuredKey` round-trip goes through `biometric_storage`'s platform
/// channel (real Keystore/Keychain + a biometric prompt), so it is
/// **device-verified**, not covered by this suite.
void main() {
  group('biometricAvailableFrom', () {
    test('false when hardware cannot check biometrics', () {
      expect(
        biometricAvailableFrom(false, const [BiometricType.fingerprint]),
        isFalse,
      );
    });

    test('false when no biometric is enrolled', () {
      expect(biometricAvailableFrom(true, const []), isFalse);
    });

    test('true when checkable and at least one biometric is enrolled', () {
      expect(
        biometricAvailableFrom(true, const [BiometricType.face]),
        isTrue,
      );
    });
  });
}
