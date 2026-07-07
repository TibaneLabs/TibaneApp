import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet_service.dart';

/// Unit tests for the post-tx confirmation gate (Solution A). Guards that we
/// only RPC-confirm Solana txs with a real signature — RPC-confirming a
/// non-Solana tx would only ever time out.
void main() {
  group('shouldRpcConfirm', () {
    test('Solana tx with a signature -> confirm', () {
      expect(shouldRpcConfirm(signature: 'sig123', isSolana: true), isTrue);
    });

    test('non-Solana tx is never RPC-confirmed (would just time out)', () {
      expect(shouldRpcConfirm(signature: '0xabc', isSolana: false), isFalse);
    });

    test('null signature -> skip', () {
      expect(shouldRpcConfirm(signature: null, isSolana: true), isFalse);
    });

    test('empty signature -> skip', () {
      expect(shouldRpcConfirm(signature: '', isSolana: true), isFalse);
    });
  });
}
