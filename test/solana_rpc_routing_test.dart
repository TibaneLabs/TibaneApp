import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/services/rpc_service.dart';

void main() {
  test('routes verified Solana reads to ModChain', () async {
    final methods = <String>[];
    final service = RpcService.real(
      client: MockClient((request) async {
        expect(request.url.toString(), modchainSolanaRpcUrl);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final method = body['method'] as String;
        methods.add(method);
        final result = switch (method) {
          'getBalance' => {'value': 123},
          'getAccountInfo' => {
            'value': {
              'data': [
                base64Encode([1, 2, 3]),
                'base64',
              ],
              'lamports': 456,
              'owner': systemProgramId,
            },
          },
          'getLatestBlockhash' => {
            'value': {'blockhash': 'test-blockhash'},
          },
          'getSignatureStatuses' => {
            'value': [
              {'confirmationStatus': 'confirmed'},
            ],
          },
          'getSignaturesForAddress' => [
            {'signature': 'test-signature'},
          ],
          'getTransaction' => {
            'meta': {'err': null},
          },
          _ => throw StateError('Unexpected method: $method'),
        };
        return http.Response(jsonEncode({'result': result}), 200);
      }),
    );

    expect(await service.getBalance(systemProgramId), BigInt.from(123));
    expect(
      await service.getAccountInfo(systemProgramId),
      Uint8List.fromList([1, 2, 3]),
    );
    final info = await service.getAccountInfoFull(systemProgramId);
    expect(info?.lamports, BigInt.from(456));
    expect(await service.getLatestBlockhash(), 'test-blockhash');
    expect(await service.confirmTransaction('test-signature'), isTrue);
    expect(
      (await service.getSignaturesForAddress(
        systemProgramId,
      )).single['signature'],
      'test-signature',
    );
    expect(methods, [
      'getBalance',
      'getAccountInfo',
      'getAccountInfo',
      'getLatestBlockhash',
      'getSignatureStatuses',
      'getSignaturesForAddress',
    ]);
    expect(
      (await service.getParsedTransaction('test-signature'))!['meta']['err'],
      isNull,
    );
    expect(methods.last, 'getTransaction');
    service.dispose();
  });

  test(
    'retains unverified methods on Helius, including SPL discovery and DAS',
    () async {
      final methods = <String>[];
      final service = RpcService.real(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final method = body['method'] as String;
          methods.add(method);
          expect(
            request.url.toString(),
            method == 'getTokenSupply' ? modchainSolanaRpcUrl : heliusRpcUrl,
          );
          final result = switch (method) {
            'getTokenAccountsByOwner' => {'value': <dynamic>[]},
            'getProgramAccounts' => <dynamic>[],
            'simulateTransaction' => {
              'value': {'err': null},
            },
            'getTokenLargestAccounts' => {
              'value': [
                {'address': 'holder', 'amount': '5'},
              ],
            },
            'getTokenSupply' => {
              'value': {'amount': '10'},
            },
            'getAssetsByOwner' => {'items': <dynamic>[]},
            'getAssetProof' => null,
            'getAsset' => null,
            'getAssetBatch' => <dynamic>[],
            _ => throw StateError('Unexpected method: $method'),
          };
          return http.Response(jsonEncode({'result': result}), 200);
        }),
      );

      expect(await service.getTokenAccountsByOwner(systemProgramId), isEmpty);
      expect(
        await service.getTokenAccountsByOwner(systemProgramId, token2022: true),
        isEmpty,
      );
      expect(await service.getPoolMemberCount(systemProgramId), 0);
      expect(
        (await service.simulateTransaction(Uint8List.fromList([1])))['err'],
        isNull,
      );
      expect((await service.getTopHolders(usdcMint)).single.percentage, 50);
      expect(await service.getAssetsByOwner(systemProgramId), isEmpty);
      expect(await service.getAssetProof(usdcMint), isNull);
      expect(await service.getAsset(usdcMint), isNull);
      expect(await service.getAssetBatch([usdcMint]), isEmpty);
      expect(methods, [
        'getTokenAccountsByOwner',
        'getTokenAccountsByOwner',
        'getProgramAccounts',
        'simulateTransaction',
        'getTokenLargestAccounts',
        'getTokenSupply',
        'getAssetsByOwner',
        'getAssetProof',
        'getAsset',
        'getAssetBatch',
      ]);
      service.dispose();
    },
  );
}
