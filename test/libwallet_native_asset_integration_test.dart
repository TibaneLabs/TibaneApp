@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/solana_private_key.dart';

void main() {
  for (final chain in ['ethereum', 'solana']) {
    test('imported $chain native balance is included in assets.list', () async {
      final directory = await Directory.systemTemp.createTemp(
        'tibane-native-$chain-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <Map<String, dynamic>>[];
      final amount = chain == 'solana'
          ? BigInt.from(1234567890)
          : BigInt.parse('1234567890000000000');
      const solanaRentReserve = 890880;
      final subscription = server.listen((request) async {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        requests.add(body);
        final result = switch (body['method']) {
          'eth_getBalance' => '0x${amount.toRadixString(16)}',
          'eth_blockNumber' || 'eth_chainId' => '0x1',
          'eth_call' => '0x0',
          'getMinimumBalanceForRentExemption' => solanaRentReserve,
          'getBalance' => {
            'context': {'slot': 1},
            'value': amount.toInt(),
          },
          'getTokenAccountsByOwner' => {
            'context': {'slot': 1},
            'value': <Object>[],
          },
          'getAccountInfo' => {
            'context': {'slot': 1},
            'value': null,
          },
          'getSignaturesForAddress' => <Object>[],
          _ => null,
        };
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
        );
        await request.response.close();
      });
      final nativeBuild = Directory(
        '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
      );
      final binary = nativeBuild.listSync().whereType<File>().singleWhere(
        (file) => file.path.endsWith('.dylib'),
      );
      final client = LibwalletClient.initialize(
        directory.path,
        library: DynamicLibrary.open(binary.path),
      );
      addTearDown(() async {
        client.dispose();
        await server.close(force: true);
        await subscription.cancel();
        await directory.delete(recursive: true);
      });
      await client.ready;
      expect(await client.info.version(), libwalletPackageVersion);

      final type = chain == 'solana' ? NetworkType.solana : NetworkType.evm;
      final networks = await client.networks.list(testNet: false);
      final network = networks.firstWhere(
        (network) =>
            network.type == type &&
            (chain == 'solana' || network.chainId == '1'),
      );
      await client.networks.update(
        network.id,
        rpc: 'http://127.0.0.1:${server.port}',
      );
      await client.networks.setCurrent(network.id);
      final privateKey = chain == 'solana'
          ? (await normalizeSolanaPrivateKey(
              '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
            )).seedHex
          : '0000000000000000000000000000000000000000000000000000000000000001';
      final storeKey = await client.storeKeys.create();
      final wallet = await client.wallets.importPrivateKey(
        privateKey: privateKey,
        curve: chain == 'solana' ? 'ed25519' : 'secp256k1',
        name: 'Native balance test',
        keys: [KeyDescription.storeKey(storeKey.publicKey)],
        format: chain == 'solana' ? 'seed' : null,
      );
      final account = await client.accounts.create(
        name: 'Imported account',
        wallet: wallet.id,
        type: chain,
        index: 0,
      );
      await client.accounts.setCurrent(account.id);

      final native = await client.accounts.nativeAsset(account.id);
      final assets = await client.assets.list();
      final listed = assets.where((asset) => asset.isNative).single;
      // LibWallet reports spendable SOL after the system-account rent reserve.
      final expectedAmount = chain == 'solana'
          ? amount - BigInt.from(solanaRentReserve)
          : amount;
      expect(native.key, '${network.type.name}.${network.chainId}.NATIVE');
      expect(native.amount.value, expectedAmount);
      expect(listed.key, native.key);
      expect(listed.amount.value, expectedAmount);
      expect(listed.amount.exp, chain == 'solana' ? 9 : 18);
      final method = chain == 'solana' ? 'getBalance' : 'eth_getBalance';
      expect(
        requests.any(
          (request) =>
              request['method'] == method &&
              (request['params'] as List).first == account.address,
        ),
        isTrue,
      );
    });
  }
}
