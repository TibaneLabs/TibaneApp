@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/send_asset.dart';
import 'package:tibaneapp/services/coinbase_spot_price_service.dart';
import 'package:tibaneapp/services/ethereum_rpc_service.dart';

const _live = bool.fromEnvironment('MULTICHAIN_LIVE_RPC');
const _symbols = ['ETH', 'BTC', 'BCH', 'LTC', 'DOGE'];
const _publicEthereum = '0x7e5f4552091a69125d5dfcb7b8c2659029395bdf';

DynamicLibrary _library() {
  final dir = Directory(
    '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
  );
  return DynamicLibrary.open(
    dir
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.dylib'))
        .path,
  );
}

void main() {
  late Directory directory;
  late FfiTransport transport;
  late List<Network> networks;
  final resolvedRpcs = <String, String>{};
  final publicAddresses = <String, String>{};
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'tibane-multichain-audit-',
    );
    transport = FfiTransport.initialize(directory.path, library: _library());
    networks = await NetworkApi(transport).list(testNet: false);
    if (_live) {
      final store = await StoreKeyApi(transport).create();
      final wallet = await WalletApi(transport).importPrivateKey(
        name: 'Public scalar-one fixture',
        privateKey:
            '0000000000000000000000000000000000000000000000000000000000000001',
        curve: 'secp256k1',
        keys: [KeyDescription.storeKey(store.publicKey)],
      );
      final account = await AccountApi(transport).create(
        wallet: wallet.id,
        type: 'bitcoin',
        name: 'Public scalar-one fixture',
      );
      for (final symbol in _symbols.where((s) => s != 'ETH')) {
        final network = networks.singleWhere((n) => n.currencySymbol == symbol);
        final formats = await AccountApi(
          transport,
        ).addressFormats(account.id, network: network.id);
        publicAddresses[symbol] = formats.formats.first.address;
      }
    }
    for (final symbol in _symbols) {
      final network = networks.singleWhere(
        (n) =>
            n.currencySymbol == symbol && (symbol != 'ETH' || n.chainId == '1'),
      );
      final resolved = await transport.request('Network:resolveRPC', 'POST', {
        'Id': network.id,
      });
      if (resolved is Map) {
        resolvedRpcs[symbol] = resolved['rpc'] as String;
      } else if (resolved is String) {
        resolvedRpcs[symbol] = resolved;
      }
    }
  });
  tearDownAll(() async {
    transport.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'official mainnet configuration covers the five non-Solana currencies',
    () {
      expect(libwalletPackageVersion, '0.5.9');
      for (final symbol in _symbols) {
        final network = networks.singleWhere(
          (n) =>
              n.currencySymbol == symbol &&
              (symbol != 'ETH' || n.chainId == '1'),
        );
        expect(Uri.parse(resolvedRpcs[symbol]!).scheme, 'https');
        expect(network.txHistoryProvider, 'modchain');
        // The SDK's default metadata reports 18 even on Bitcoin-family nets.
        // The app must use Amount.exp or its chain-family fallback, not that.
        expect(
          nativeDecimalsForType(network.type.name),
          symbol == 'ETH' ? 18 : 8,
        );
        // Public, default SDK configuration only; no user database is opened.
        printOnFailure(
          'AUDIT_NETWORK ${jsonEncode({'symbol': symbol, 'id': network.id, 'type': network.type.name, 'chainId': network.chainId, 'rpc': network.rpc, 'historyProvider': network.txHistoryProvider, 'explorer': network.resolvedBlockExplorer})}',
        );
      }
    },
  );

  test(
    'live ETH balance uses the app direct ModChain endpoint',
    () async {
      final service = EthereumRpcService();
      addTearDown(service.dispose);
      expect(
        await service.getBalanceWei(_publicEthereum),
        greaterThanOrEqualTo(BigInt.zero),
      );
    },
    skip: !_live
        ? 'Enable MULTICHAIN_LIVE_RPC for public read-only checks'
        : false,
  );

  for (final symbol in _symbols) {
    test(
      'live $symbol USD quote uses the app price service',
      () async {
        final service = CoinbaseSpotPriceService(symbol: symbol);
        addTearDown(service.dispose);
        final price = await service.getPriceUsd();
        expect(price.isFinite && price > 0, true);
      },
      skip: !_live
          ? 'Enable MULTICHAIN_LIVE_RPC for public read-only checks'
          : false,
    );
    test(
      'live read-only $symbol RPC responds on the official default endpoint',
      () async {
        final rpc = HttpClient()
          ..connectionTimeout = const Duration(seconds: 10);
        addTearDown(() => rpc.close(force: true));
        Future<dynamic> read(String method, List<Object?> params) async {
          final request = await rpc.postUrl(Uri.parse(resolvedRpcs[symbol]!));
          request.headers.contentType = ContentType.json;
          request.write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': method,
              'params': params,
            }),
          );
          final response = await request.close().timeout(
            const Duration(seconds: 20),
          );
          expect(response.statusCode, 200, reason: '$symbol $method HTTP');
          final data =
              jsonDecode(await utf8.decoder.bind(response).join()) as Map;
          expect(data['error'], isNull, reason: '$symbol $method');
          return data['result'];
        }

        if (symbol == 'ETH') {
          expect(await read('eth_chainId', []), '0x1');
          expect(
            BigInt.parse(
              (await read('eth_blockNumber', []) as String).substring(2),
              radix: 16,
            ),
            greaterThan(BigInt.zero),
          );
          expect(
            await read('eth_getBalance', [_publicEthereum, 'latest']),
            matches(RegExp(r'^0x[0-9a-fA-F]+$')),
          );
          // USDC decimals, a read-only ERC-20 eth_call.
          expect(
            BigInt.parse(
              (await read('eth_call', [
                        {
                          'to': '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
                          'data': '0x313ce567',
                        },
                        'latest',
                      ])
                      as String)
                  .substring(2),
              radix: 16,
            ),
            BigInt.from(6),
          );
        } else {
          final info = await read('getblockchaininfo', []) as Map;
          expect(info['blocks'], greaterThan(0));
          expect(info['chain'], 'main');
          final assets =
              await read('modchain_assets', [publicAddresses[symbol]]) as Map;
          expect(assets['assets'], isA<List>());
        }
      },
      skip: !_live
          ? 'Enable MULTICHAIN_LIVE_RPC for public read-only checks'
          : false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
