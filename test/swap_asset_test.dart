import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show NetworkType;
import 'package:tibaneapp/constants/solana_constants.dart' show wsolMint;
import 'package:tibaneapp/services/wallet/swap_asset.dart';

/// Unit tests for the chain-aware swap token-ref helpers (Phase 5b). The full
/// swap flow (quote/execute) is device-verified on Solana; these pin the OKX
/// address construction that decides which chain's token is quoted/swapped.
void main() {
  group('nativeSwapMint', () {
    test('Solana → wSOL mint (unchanged)', () {
      expect(nativeSwapMint(NetworkType.solana), wsolMint);
    });
    test('EVM / Bitcoin → NATIVE sentinel', () {
      expect(nativeSwapMint(NetworkType.evm), 'NATIVE');
      expect(nativeSwapMint(NetworkType.bitcoin), 'NATIVE');
    });
  });

  group('swapTokenAddress', () {
    test('Solana native (wSOL) → NATIVE (matches old wsolMint check)', () {
      final native = nativeSwapMint(NetworkType.solana);
      expect(swapTokenAddress(wsolMint, nativeMint: native), 'NATIVE');
    });
    test('Solana SPL token → mint unchanged', () {
      final native = nativeSwapMint(NetworkType.solana);
      expect(swapTokenAddress('Mint111', nativeMint: native), 'Mint111');
    });
    test('EVM native → NATIVE', () {
      final native = nativeSwapMint(NetworkType.evm);
      expect(swapTokenAddress('NATIVE', nativeMint: native), 'NATIVE');
    });
    test('EVM ERC-20 → contract unchanged', () {
      final native = nativeSwapMint(NetworkType.evm);
      expect(swapTokenAddress('0xabc', nativeMint: native), '0xabc');
    });
  });

  group('isNativeSwapMint', () {
    test('Solana', () {
      final n = nativeSwapMint(NetworkType.solana);
      expect(isNativeSwapMint(wsolMint, nativeMint: n), isTrue);
      expect(isNativeSwapMint('Mint111', nativeMint: n), isFalse);
    });
    test('EVM', () {
      final n = nativeSwapMint(NetworkType.evm);
      expect(isNativeSwapMint('NATIVE', nativeMint: n), isTrue);
      expect(isNativeSwapMint('0xabc', nativeMint: n), isFalse);
    });
  });
}
