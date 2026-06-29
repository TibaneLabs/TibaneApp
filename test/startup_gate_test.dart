import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/main.dart' show startupGateReady;

/// Unit tests for the startup splash gate (Phase 7 / D16). The full splash
/// widget + WalletService.dataReady wiring is device-verified; this pins the
/// pure reveal decision.
void main() {
  group('startupGateReady', () {
    test('migration check pending → not ready (hold splash)', () {
      expect(
        startupGateReady(needsMigration: null, walletDataReady: true),
        isFalse,
      );
      expect(
        startupGateReady(needsMigration: null, walletDataReady: false),
        isFalse,
      );
    });

    test('migration needed → reveal now (migration screen comes next)', () {
      expect(
        startupGateReady(needsMigration: true, walletDataReady: false),
        isTrue,
      );
    });

    test('no migration → gated on wallet data being ready', () {
      expect(
        startupGateReady(needsMigration: false, walletDataReady: false),
        isFalse,
      );
      expect(
        startupGateReady(needsMigration: false, walletDataReady: true),
        isTrue,
      );
    });
  });
}
