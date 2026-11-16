import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

CuratedToken _token(
  String address, {
  String symbol = 'GOAT',
  bool verified = false,
}) => CuratedToken(
  chainKey: 'solana.mainnet',
  address: address,
  symbol: symbol,
  name: '$symbol token',
  decimals: 6,
  type: 'spl-token',
  verified: verified,
);

void main() {
  test('verified matches come first even beyond the result limit', () {
    final results = LibwalletBackend.rankCuratedTokenMatches(
      [
        _token('unverified-1'),
        _token('unverified-2'),
        _token('unverified-3'),
        _token('verified-1', verified: true),
        _token('verified-2', verified: true),
        _token('unrelated', symbol: 'JUP', verified: true),
      ],
      ' GOAT ',
      3,
    );

    expect(results.map((r) => r.mint), [
      'verified-1',
      'verified-2',
      'unverified-1',
    ]);
    expect(results.map((r) => r.verified), [true, true, false]);
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
