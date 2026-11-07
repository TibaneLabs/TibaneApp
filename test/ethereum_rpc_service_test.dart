import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tibaneapp/services/ethereum_rpc_service.dart';

void main() {
  const address = '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';

  test('reads native ETH balance in wei from the Mod Chain RPC', () async {
    final service = EthereumRpcService(
      client: MockClient((request) async {
        expect(
          request.url.toString(),
          'https://rpc.modchain.net/chain/ethereum/rpc',
        );
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['method'], 'eth_getBalance');
        expect(body['params'], [address, 'latest']);
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': '0xde0b6b3a7640000',
          }),
          200,
        );
      }),
    );

    expect(await service.getBalanceWei(address), BigInt.from(10).pow(18));
    service.dispose();
  });

  test('rejects invalid addresses before making an RPC call', () async {
    final service = EthereumRpcService(
      client: MockClient((_) async => throw StateError('Unexpected request')),
    );

    await expectLater(
      service.getBalanceWei('not-an-ethereum-address'),
      throwsFormatException,
    );
    service.dispose();
  });

  test('rejects RPC errors and malformed balances', () async {
    final service = EthereumRpcService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'error': {'code': -1},
          }),
          200,
        ),
      ),
    );
    await expectLater(service.getBalanceWei(address), throwsFormatException);
    service.dispose();

    final malformed = EthereumRpcService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': 'not-hex'}),
          200,
        ),
      ),
    );
    await expectLater(malformed.getBalanceWei(address), throwsFormatException);
    malformed.dispose();
  });
}
