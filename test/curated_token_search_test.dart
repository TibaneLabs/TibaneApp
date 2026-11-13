import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

class _VerifiedToken extends CuratedToken {
  const _VerifiedToken(String address, {String symbol = 'GOAT'})
    : super(
        chainKey: 'solana.mainnet',
        address: address,
        symbol: symbol,
        name: symbol,
        decimals: 6,
        type: 'spl-token',
      );

  bool get verified => true;
}

CuratedToken _token(String address) => CuratedToken(
  chainKey: 'solana.mainnet',
  address: address,
  symbol: 'GOAT',
  name: 'Goat token',
  decimals: 6,
  type: 'spl-token',
);

void main() {
  test('verified matches come first even beyond the result limit', () {
    final results = LibwalletBackend.rankCuratedTokenMatches(
      [
        _token('unverified-1'),
        _token('unverified-2'),
        _token('unverified-3'),
        const _VerifiedToken('verified-1'),
        const _VerifiedToken('verified-2'),
        const _VerifiedToken('unrelated', symbol: 'JUP'),
      ],
      ' GOAT ',
      3,
    );

    expect(results.map((r) => r.mint), [
      'verified-1',
      'verified-2',
      'unverified-1',
    ]);
  });

  test('legacy catalog keeps its order and still supports mint queries', () {
    final tokens = [_token('FirstMint'), _token('SecondMint')];
    final results = LibwalletBackend.rankCuratedTokenMatches(tokens, 'mint', 2);
    expect(results.map((r) => r.mint), ['FirstMint', 'SecondMint']);
    expect(
      LibwalletBackend.rankCuratedTokenMatches(tokens, 'mint', 0),
      isEmpty,
    );
  });
}
