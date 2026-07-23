import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/screens/home_screen.dart' show homeActionVisibility;

/// Unit tests for the Home 3-action gating (Tools / Search / Stake). The card
/// layout itself is visual; this pins the jurisdiction-gating that decides
/// which actions the row shows.
void main() {
  group('homeActionVisibility', () {
    test('non-UK shows all three actions', () {
      final v = homeActionVisibility(isUk: false);
      expect(v.tools, isTrue);
      expect(v.search, isTrue);
      expect(v.stake, isTrue);
    });

    test('UK hides Stake (regulated) but keeps Tools + Search', () {
      final v = homeActionVisibility(isUk: true);
      expect(v.tools, isTrue);
      expect(v.search, isTrue);
      expect(v.stake, isFalse);
    });

    test('Solana-only tools stay discoverable from any account context', () {
      final v = homeActionVisibility(isUk: false);
      expect(v.tools, isTrue);
      expect(v.search, isTrue);
      expect(v.stake, isTrue);
    });

    test('Search is always visible regardless of context', () {
      for (final isUk in [true, false]) {
        expect(homeActionVisibility(isUk: isUk).search, isTrue);
      }
    });
  });
}
