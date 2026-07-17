import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/screens/home_screen.dart' show homeActionVisibility;

/// Unit tests for the Home 3-action gating (Tools / Search / Stake). The card
/// layout itself is visual; this pins the chain- and jurisdiction-gating that
/// decides which actions the row shows.
void main() {
  group('homeActionVisibility', () {
    test('Solana + non-UK shows all three actions', () {
      final v = homeActionVisibility(isUk: false, solana: true);
      expect(v.tools, isTrue);
      expect(v.search, isTrue);
      expect(v.stake, isTrue);
    });

    test('UK hides Stake (regulated) but keeps Tools + Search', () {
      final v = homeActionVisibility(isUk: true, solana: true);
      expect(v.tools, isTrue);
      expect(v.search, isTrue);
      expect(v.stake, isFalse);
    });

    test('non-Solana account hides Tools + Stake, keeps Search', () {
      final v = homeActionVisibility(isUk: false, solana: false);
      expect(v.tools, isFalse);
      expect(v.search, isTrue);
      expect(v.stake, isFalse);
    });

    test('Search is always visible regardless of context', () {
      for (final isUk in [true, false]) {
        for (final solana in [true, false]) {
          expect(
            homeActionVisibility(isUk: isUk, solana: solana).search,
            isTrue,
          );
        }
      }
    });
  });
}
