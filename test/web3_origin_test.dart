import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet/web3_origin.dart';

void main() {
  test('keeps only the canonical HTTP security origin', () {
    expect(
      web3SecurityOrigin('https://Example.COM:8443/swap?token=secret#route'),
      'https://example.com:8443',
    );
    expect(
      web3SecurityOrigin('https://example.com/wallet'),
      'https://example.com',
    );
  });

  test('rejects opaque and non-web origins', () {
    expect(web3SecurityOrigin('about:blank'), isNull);
    expect(web3SecurityOrigin('walletconnect:'), isNull);
    expect(web3SecurityOrigin('not a url'), isNull);
  });
}
