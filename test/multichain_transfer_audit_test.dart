@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

const _owner = '0x7e5f4552091a69125d5dfcb7b8c2659029395bdf';
const _recipient = '0x0000000000000000000000000000000000000002';
const _contract = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
// Chain-specific adapter regressions run by default against the native release
// and a loopback RPC. They never authorize or broadcast transactions.

class _Client implements LibwalletClient {
  _Client(Transport transport, this.transactions)
    : networks = NetworkApi(transport),
      accounts = AccountApi(transport);
  @override
  final AccountApi accounts;
  @override
  final NetworkApi networks;
  @override
  final TransactionApi transactions;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(this.client, this.source);
  final LibwalletClient client;
  final String source;
  @override
  String? get accountId => source;
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

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
  late Directory directory;
  late FfiTransport transport;
  late HttpServer server;
  late TransactionApi transactions;
  late _Backend backend;
  final requests = <Map<String, dynamic>>[];
  late Account ethereum;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tibane-transfer-audit-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests.clear();
    server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(body);
      final method = body['method'];
      final result = switch (method) {
        'eth_getBalance' => '0xde0b6b3a7640000',
        'eth_blockNumber' || 'eth_chainId' => '0x1',
        'eth_gasPrice' => '0x3b9aca00',
        'eth_getTransactionCount' => '0x0',
        'eth_maxPriorityFeePerGas' => '0x3b9aca00',
        'eth_getCode' || 'eth_call' => '0x',
        'eth_estimateGas' => '0x5208',
        'modchain_assets' => {
          'assets': [
            {'asset': 'NATIVE', 'balance': '1.23456789'},
          ],
        },
        'estimatesmartfee' => {'feerate': 0.00001, 'blocks': 6},
        _ => null,
      };
      final error = method == 'debug_traceCall'
          ? {'code': -32601, 'message': 'fixture: tracing disabled'}
          : null;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': body['id'],
          if (error != null) 'error': error else 'result': result,
        }),
      );
      await request.response.close();
    });
    final binary = Directory(
      '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
    ).listSync().whereType<File>().singleWhere((f) => f.path.endsWith('.dylib'));
    transport = FfiTransport.initialize(
      directory.path,
      library: DynamicLibrary.open(binary.path),
    );
    final networks = NetworkApi(transport);
    final network = (await networks.list(
      testNet: false,
    )).firstWhere((n) => n.type == NetworkType.evm && n.chainId == '1');
    await networks.update(network.id, rpc: 'http://127.0.0.1:${server.port}');
    await networks.setCurrent(network.id);
    ethereum = await AccountApi(
      transport,
    ).createView(type: 'ethereum', address: _owner);
    transactions = TransactionApi(
      _LocalRpc(transport, 'http://127.0.0.1:${server.port}'),
    );
    backend = _Backend(_Client(transport, transactions), ethereum.id);
  });
  tearDown(() async {
    backend.dispose();
    transport.dispose();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test(
    'EVM native simulation resolves account ID and transfers the requested wei',
    () async {
      final amount = Amount(BigInt.parse('123456789012345678'), 18);
      final simulation = await backend.simulateSend(
        to: _recipient,
        amount: amount,
        asset: 'evm.1.NATIVE',
      );
      printOnFailure(
        'AUDIT_ETH_SIM ${jsonEncode({'chain': simulation.chain, 'revert': simulation.willRevert, 'calls': requests})}',
      );
      expect(simulation.chain, 'evm');
      expect(simulation.willRevert, false);
      final call =
          (requests.firstWhere((r) => r['method'] == 'eth_call')['params']
                      as List)
                  .first
              as Map;
      expect((call['from'] as String).toLowerCase(), _owner);
      expect((call['to'] as String).toLowerCase(), _recipient);
      expect(
        BigInt.parse((call['value'] as String).substring(2), radix: 16),
        amount.value,
      );
      expect(
        requests.any((r) => (r['method'] as String).contains('send')),
        false,
      );
    },
  );

  test(
    'ERC-20 simulation targets the contract with encoded recipient and token units',
    () async {
      final simulation = await backend.simulateSend(
        to: _recipient,
        amount: Amount(BigInt.from(1234567), 6),
        asset: 'evm.1.$_contract',
      );
      printOnFailure(
        'AUDIT_ERC20_SIM ${jsonEncode({'chain': simulation.chain, 'revert': simulation.willRevert, 'calls': requests})}',
      );
      expect(simulation.chain, 'evm');
      expect(simulation.willRevert, false);
      final call =
          (requests.firstWhere((r) => r['method'] == 'eth_call')['params']
                      as List)
                  .first
              as Map;
      expect((call['to'] as String).toLowerCase(), _contract.toLowerCase());
      expect(
        call['data'],
        '0xa9059cbb${_recipient.substring(2).padLeft(64, '0')}${BigInt.from(1234567).toRadixString(16).padLeft(64, '0')}',
      );
      expect(
        requests.any((r) => (r['method'] as String).contains('send')),
        false,
      );
    },
  );

  test(
    'low-level EVM simulation accepts address/value calldata as a control',
    () async {
      final amount = Amount(BigInt.parse('123456789012345678'), 18);
      final sim = await transactions.simulate(
        UnsignedTransaction(
          type: 'evm',
          from: _owner,
          to: _recipient,
          value: amount,
        ),
      );
      expect(sim.willRevert, false);
      final call =
          (requests.firstWhere((r) => r['method'] == 'eth_call')['params']
                      as List)
                  .first
              as Map;
      expect(call['from'], _owner);
      expect(
        BigInt.parse((call['value'] as String).substring(2), radix: 16),
        amount.value,
      );
    },
  );

  test('EVM MAX reserves a gas fee from its native balance', () async {
    final result = await transactions.maxSendable(
      from: ethereum.id,
      asset: 'evm.1.NATIVE',
    );
    expect(result.chain, 'evm');
    expect(result.balance.value, BigInt.parse('1000000000000000000'));
    expect(result.max.exp, 18);
    expect(result.fee.value, greaterThan(BigInt.zero));
    expect(result.max.value + result.fee.value, result.balance.value);
  });

  for (final symbol in ['BTC', 'BCH', 'LTC', 'DOGE']) {
    test(
      '$symbol native balance has eight decimals and ModChain history is available',
      () async {
        final networks = NetworkApi(transport);
        final network = (await networks.list(
          testNet: false,
        )).singleWhere((n) => n.currencySymbol == symbol);
        await networks.update(
          network.id,
          rpc: 'http://127.0.0.1:${server.port}',
        );
        await networks.setCurrent(network.id);
        final address = switch (symbol) {
          'BTC' => '1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH',
          'BCH' => 'bitcoincash:qp63uahgrxged4z5jswyt5dn5v3lzsem6cy4spdc2h',
          'LTC' => 'LVuDpNCSSj6pQ7t9Pv6d6sUkLKoqDEVUnJ',
          _ => 'DFpN6QqF9Um3gKNaxN6tNcab1FArL9cZLE',
        };
        final accounts = AccountApi(
          _LocalRpc(transport, 'http://127.0.0.1:${server.port}'),
        );
        final account = await accounts.createView(
          type: 'bitcoin',
          address: address,
        );
        final asset = await accounts.nativeAsset(
          account.id,
          network: network.id,
        );
        expect(asset.key, 'bitcoin.${network.chainId}.NATIVE');
        expect(asset.amount.exp, 8);
        expect(asset.amount.value, BigInt.from(123456789));
        expect(network.txHistoryProvider, 'modchain');
        expect(requests.any((r) => r['method'] == 'modchain_assets'), true);
        final simulation = await transactions.simulate(
          UnsignedTransaction(
            type: 'transfer',
            from: account.id,
            to: address,
            amount: Amount(BigInt.from(10000), 8),
            asset: 'bitcoin.${network.chainId}.NATIVE',
          ),
        );
        printOnFailure(
          'AUDIT_${symbol}_SIM ${jsonEncode({'chain': simulation.chain, 'revert': simulation.willRevert, 'fee': simulation.bitcoinFee, 'methods': requests.map((r) => r['method']).toList()})}',
        );
        expect(simulation.chain, 'bitcoin');
      },
    );
  }
}
