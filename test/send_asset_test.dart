import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet/send_asset.dart';

/// Unit tests for the chain-aware send asset-key helpers (Phase 5a). The send
/// screen's full flow (simulate/sign/broadcast) is device-verified; these pin
/// the key construction that decides which chain's asset is moved.
void main() {
  group('sendAssetKey', () {
    test('null/empty mint → null (native path)', () {
      expect(
        sendAssetKey(mint: null, networkType: 'solana', chainId: 'mainnet'),
        isNull,
      );
      expect(
        sendAssetKey(mint: '', networkType: 'ethereum', chainId: '1'),
        isNull,
      );
    });

    test('Solana token → unchanged solana.mainnet.<mint>', () {
      expect(
        sendAssetKey(mint: 'Mint111', networkType: 'solana', chainId: 'mainnet'),
        'solana.mainnet.Mint111',
      );
    });

    test('EVM token → ethereum.<chainId>.<contract>', () {
      expect(
        sendAssetKey(mint: '0xabc', networkType: 'ethereum', chainId: '1'),
        'ethereum.1.0xabc',
      );
    });
  });

  group('nativeDecimalsForType', () {
    test('Solana = 9 (lamports) — never 18', () {
      expect(nativeDecimalsForType('solana'), 9);
    });
    test('EVM = 18 (wei)', () {
      expect(nativeDecimalsForType('evm'), 18);
      expect(nativeDecimalsForType('ethereum'), 18);
    });
    test('Bitcoin = 8 (sats)', () {
      expect(nativeDecimalsForType('bitcoin'), 8);
    });
    test('unknown → Solana-first 9', () {
      expect(nativeDecimalsForType('bogus'), 9);
      expect(nativeDecimalsForType(''), 9);
    });
  });

  group('mintFromAssetKey', () {
    test('round-trips with sendAssetKey', () {
      const key = 'ethereum.1.0xabc';
      final mint = mintFromAssetKey(key);
      expect(mint, '0xabc');
      expect(
        sendAssetKey(mint: mint, networkType: 'ethereum', chainId: '1'),
        key,
      );
    });

    test('solana key → bare mint', () {
      expect(mintFromAssetKey('solana.mainnet.Mint111'), 'Mint111');
    });

    test('native key → NATIVE segment', () {
      expect(mintFromAssetKey('ethereum.1.NATIVE'), 'NATIVE');
    });

    test('malformed key → empty', () {
      expect(mintFromAssetKey('nodots'), '');
      expect(mintFromAssetKey('trailing.'), '');
    });
  });
}
