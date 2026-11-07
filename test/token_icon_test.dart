import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/widgets/token_icon.dart';

void main() {
  group('tokenImageCandidates', () {
    test('adds a fallback gateway for an HTTP IPFS URL', () {
      const cid = 'bafybeiagakzt7mexds2iehvwzlit6lf4r4rcvzch6qhork5ty7bwktslci';

      expect(tokenImageCandidates('https://ipfs.io/ipfs/$cid'), [
        'https://ipfs.io/ipfs/$cid',
        'https://gateway.pinata.cloud/ipfs/$cid',
      ]);
    });

    test('supports native ipfs URLs and leaves regular URLs unchanged', () {
      expect(tokenImageCandidates('ipfs://abc/image.png'), [
        'ipfs://abc/image.png',
        'https://gateway.pinata.cloud/ipfs/abc/image.png',
      ]);
      expect(tokenImageCandidates('https://example.com/token.png'), [
        'https://example.com/token.png',
      ]);
    });
  });
}
