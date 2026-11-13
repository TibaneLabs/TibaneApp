@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';

// Keep the native history reader isolated from all production RPC endpoints.
class _LocalRpc implements Transport {
  _LocalRpc(this.inner, this.rpc);
  final Transport inner;
  final String rpc;
  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) => inner.request(path, verb, {...?params, 'RPC': rpc});
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('official native backfill loads a swap-shaped Solana transaction', () async {
    const owner = '11111111111111111111111111111111';
    // libwallet 0.5.9 keeps only rows whose id is a real Solana signature
    // (base58 of 64 bytes).
    const signature =
        '4S55ApgNWn8YKQL5J2uuxtfZrYXQZqBs8BUJTqGv3us4cAefggxxMLavbor7u47x4BfUhDRkfFBpW2rJTU6YMxux';
    final directory = await Directory.systemTemp.createTemp('tibane-history-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final methods = <String>[];
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      final method = body['method'] as String;
      methods.add(method);
      final result = switch (method) {
        'getSignaturesForAddress' => [
          {'signature': signature, 'blockTime': 1792497600, 'err': null},
        ],
        'getTransaction' => {
          'blockTime': 1792497600,
          'transaction': {
            'message': {
              'accountKeys': [
                {'pubkey': owner, 'signer': true},
              ],
              'instructions': [
                {'programId': 'fixture-swap-program'},
              ],
            },
          },
          'meta': {
            'err': null,
            'preBalances': [100000000],
            'postBalances': [99000000],
          },
        },
        'getBalance' => {
          'context': {'slot': 1},
          'value': 99000000,
        },
        _ => null,
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
      );
      await request.response.close();
    });
    final binary = Directory(
      '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
    ).listSync().whereType<File>().singleWhere((f) => f.path.endsWith('.dylib'));
    final transport = FfiTransport.initialize(
      directory.path,
      library: DynamicLibrary.open(binary.path),
    );
    addTearDown(() async {
      transport.dispose();
      await server.close(force: true);
      await subscription.cancel();
      await directory.delete(recursive: true);
    });
    final networks = NetworkApi(transport);
    final accounts = AccountApi(transport);
    final transactions = TransactionApi(
      _LocalRpc(transport, 'http://127.0.0.1:${server.port}'),
    );
    final network = (await networks.list(
      testNet: false,
    )).firstWhere((n) => n.type == NetworkType.solana);
    await networks.setCurrent(network.id);
    final account = await accounts.createView(type: 'solana', address: owner);
    await accounts.setCurrent(account.id);
    expect(await transactions.list(), isEmpty);
    await accounts.setCurrent(account.id);
    expect(await transactions.list(), isEmpty);
    expect(methods, isEmpty);
    final result = await transactions.backfill();
    expect(result['started'], true);
    expect(result['count'], 1);
    final history = await transactions.list();
    expect(history.single.hash, signature);
    expect(history.single.from, owner);
    expect(history.single.amount!.value, BigInt.from(1000000));
    expect(methods, containsAll(['getSignaturesForAddress', 'getTransaction']));
    expect(methods, isNot(contains('sendTransaction')));
  });
}
