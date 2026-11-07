@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';

// Public BIP-39 fixture and loopback RPC only; never user wallets or funds.
const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

class _LocalRpc implements Transport {
  _LocalRpc(this.inner);
  final Transport inner;
  String rpc = 'http://127.0.0.1:9';

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
  late _LocalRpc local;
  late WalletApi wallets;
  late NetworkApi networks;
  late AccountApi accounts;
  late TransactionApi transactions;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tibane-libwallet-058-');
    final binary =
        Directory(
          '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
        ).listSync().whereType<File>().singleWhere(
          (file) => file.path.endsWith('.dylib'),
        );
    transport = FfiTransport.initialize(
      directory.path,
      library: DynamicLibrary.open(binary.path),
    );
    local = _LocalRpc(transport);
    wallets = WalletApi(local);
    networks = NetworkApi(local);
    accounts = AccountApi(local);
    transactions = TransactionApi(local);
    expect(libwalletPackageVersion, '0.5.8');
    expect(await InfoApi(local).version(), libwalletPackageVersion);
    for (final network in await networks.list()) {
      await networks.update(network.id, rpc: local.rpc);
    }
  });

  tearDown(() async {
    transport.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'native BIP39 generation and validation support every advertised length',
    () async {
      final defaultPhrase = await wallets.generateMnemonic();
      expect(defaultPhrase.split(' '), hasLength(12));
      expect(await wallets.validateMnemonic(defaultPhrase), true);
      for (final words in [12, 15, 18, 21, 24]) {
        final phrase = await wallets.generateMnemonic(words: words);
        expect(phrase.split(' '), hasLength(words));
        expect(await wallets.validateMnemonic(phrase), true);
      }
      expect(await wallets.validateMnemonic(_phrase), true);
      expect(await wallets.validateMnemonic('abandon ' * 12), false);
      expect(await wallets.validateMnemonic('not a recovery phrase'), false);
      await expectLater(
        wallets.generateMnemonic(words: 13),
        throwsA(isA<LibwalletException>()),
      );
      expect(await wallets.list(), isEmpty);
    },
  );

  for (final symbol in ['BTC', 'BCH', 'LTC', 'DOGE']) {
    test(
      'native $symbol history sweeps receive and change, deduplicates and keeps exact amounts',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final methods = <String>[];
        final queriedAddresses = <String>{};
        String? receive;
        String? change;
        final subscription = server.listen((request) async {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final method = body['method'] as String;
          methods.add(method);
          Object? result;
          if (method == 'modchain_lookupTxoBIP32') {
            result = {'lastI': 0};
          } else if (method == 'modchain_assets') {
            result = {'assets': []};
          } else if (method == 'modchain_historyByAddress') {
            final address = (body['params'] as List).first as String;
            queriedAddresses.add(address);
            result = {
              'results': [
                if (receive != null &&
                    (address == receive || address == change))
                  for (final confirmed in [true, false])
                    {
                      'tx': confirmed ? '11' * 32 : '22' * 32,
                      'data': {
                        'confirmations': confirmed ? 3 : 0,
                        'blocktime': 1794000000,
                        'vin': [],
                        'vout': [
                          {
                            'n': 0,
                            'value': '0.12500000',
                            'scriptPubKey': {'address': receive},
                          },
                          {
                            'n': 1,
                            'value': '0.25000000',
                            'scriptPubKey': {
                              'addresses': [change],
                            },
                          },
                        ],
                      },
                    },
              ],
              'continueKey': '',
            };
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
          );
          await request.response.close();
        });
        addTearDown(() async {
          await server.close(force: true);
          await subscription.cancel();
        });
        local.rpc = 'http://127.0.0.1:${server.port}';
        final network = (await networks.list(
          testNet: false,
        )).singleWhere((network) => network.currencySymbol == symbol);
        expect(network.txHistoryProvider, 'modchain');
        await networks.update(
          network.id,
          rpc: 'http://127.0.0.1:${server.port}',
        );
        await networks.setCurrent(network.id);
        final wallet = await wallets.importMnemonic(
          mnemonic: _phrase,
          curve: 'secp256k1',
          name: 'Public history fixture',
          keys: [KeyDescription.password('offline-history-fixture')],
        );
        final account = await accounts.create(
          wallet: wallet.id,
          type: 'bitcoin',
          name: 'Offline history account',
          keys: [KeyDescription.password('offline-history-fixture').toJson()],
        );
        final addresses = await accounts.allAddresses(
          account.id,
          network: network.id,
        );
        receive = addresses.receive.first.address;
        change = addresses.change.first.address;
        await accounts.setCurrent(account.id);
        final backfill = await transactions.backfill();
        expect(backfill['started'], true);
        expect(backfill['count'], 1);
        final history = await transactions.list();
        expect(history, hasLength(1));
        expect(history.single.hash, '11' * 32);
        expect(history.single.network, network.id);
        expect(history.single.to, account.address);
        expect(history.single.amount!.value, BigInt.from(37500000));
        expect(history.single.amount!.exp, 8);
        expect(queriedAddresses, containsAll([receive, change]));
        expect((await transactions.backfill())['count'], 0);
        expect(await transactions.list(), hasLength(1));
        expect(methods, isNot(contains('sendrawtransaction')));
      },
    );
  }
}
