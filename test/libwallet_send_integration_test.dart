@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/solana_common.dart';

const _seed =
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';
const _recipient = 'HSYatVptUXtn4f5JeDBzRhceG5LoMnsL4CizfFjxS83y';
const _mint = 'GnM6XZ7DN9KSPW2ZVMNqCggsxjnxHMGb2t4kiWrUpump';

DynamicLibrary _officialLibrary() {
  final build = Directory(
    '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
  );
  return DynamicLibrary.open(
    build
        .listSync()
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('.dylib'))
        .path,
  );
}

// Pin requests to the local fixture; never broadcast or use production RPCs.
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
  test(
    'imported Solana signs before and after MPC promotion',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'tibane-signing-release-',
      );
      final client = LibwalletClient.initialize(
        dir.path,
        library: _officialLibrary(),
      );
      addTearDown(() async {
        client.dispose();
        await dir.delete(recursive: true);
      });
      await client.ready;
      expect(await client.info.version(), libwalletPackageVersion);
      final original = await client.storeKeys.create();
      final imported = await client.wallets.importPrivateKey(
        privateKey: _seed,
        curve: 'ed25519',
        format: 'seed',
        name: 'Public RFC8032 fixture',
        keys: [KeyDescription.storeKey(original.publicKey)],
      );
      expect(imported.threshold, 0);
      final account = await client.accounts.create(
        wallet: imported.id,
        name: 'Fixture',
        type: 'solana',
        index: 0,
      );
      final message = Uint8List.fromList(utf8.encode('Tibane offline test'));
      Future<void> verify(List<Map<String, dynamic>> keys) async {
        final signed = await client.accounts.signMessage(
          account.id,
          message: message,
          keys: keys,
          mode: 'solana',
        );
        if (signed.publicKey != null) expect(signed.publicKey, account.address);
        expect(
          await crypto.Ed25519().verify(
            message,
            signature: crypto.Signature(
              base58Decode(signed.signature),
              publicKey: crypto.SimplePublicKey(
                base58Decode(account.address),
                type: crypto.KeyPairType.ed25519,
              ),
            ),
          ),
          isTrue,
        );
      }

      await verify([
        SigningKey(
          id: imported.keys.single.id,
          key: original.privateKey,
          type: 'StoreKey',
        ).toJson(),
      ]);
      final stores = [
        await client.storeKeys.create(),
        await client.storeKeys.create(),
        await client.storeKeys.create(),
      ];
      await client.wallets.promote(
        imported.id,
        oldKeys: [
          KeyDescription(
            type: 'StoreKey',
            key: original.privateKey,
            id: imported.keys.single.id,
          ),
        ],
        newKeys: [
          for (final store in stores) KeyDescription.storeKey(store.publicKey),
        ],
        threshold: 1,
      );
      final promoted = await client.wallets.get(imported.id);
      expect(promoted.threshold, 1);
      expect((await client.accounts.get(account.id)).address, account.address);
      await verify([
        for (final key in promoted.keys)
          SigningKey(
            id: key.id,
            key: stores
                .singleWhere((store) => store.publicKey == key.key)
                .privateKey,
            type: 'StoreKey',
          ).toJson(),
      ]);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('official SEND MAX and SOL/SPL simulation use Solana RPC', () async {
    final dir = await Directory.systemTemp.createTemp('tibane-send-release-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Map<String, dynamic>>[];
    var failSimulation = false;
    final mintData = Uint8List(82)..[44] = 6;
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(body);
      final method = body['method'];
      final result = switch (method) {
        'getBalance' => {
          'context': {'slot': 1},
          'value': 16621000,
        },
        'getMinimumBalanceForRentExemption' =>
          (body['params'] as List).first == 0 ? 890880 : 2039280,
        'getLatestBlockhash' => {
          'context': {'slot': 1},
          'value': {
            'blockhash': '11111111111111111111111111111111',
            'lastValidBlockHeight': 100,
          },
        },
        'getAccountInfo' => {
          'context': {'slot': 1},
          'value': (body['params'] as List).first == _mint
              ? {
                  'owner': 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA',
                  'data': [base64Encode(mintData), 'base64'],
                  'lamports': 1461600,
                  'executable': false,
                  'rentEpoch': 0,
                }
              : null,
        },
        'getSignaturesForAddress' => <Object>[],
        'simulateTransaction' => {
          'context': {'slot': 1},
          'value': {
            'err': failSimulation
                ? {
                    'InstructionError': [0, 'InsufficientFunds'],
                  }
                : null,
            'logs': ['Program log: fixture'],
            'unitsConsumed': 1234,
          },
        },
        _ => null,
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
      );
      await request.response.close();
    });
    final transport = FfiTransport.initialize(
      dir.path,
      library: _officialLibrary(),
    );
    final rpc = 'http://127.0.0.1:${server.port}';
    final transactions = TransactionApi(_LocalRpc(transport, rpc));
    final networks = NetworkApi(transport);
    final accounts = AccountApi(transport);
    addTearDown(() async {
      transport.dispose();
      await server.close(force: true);
      await subscription.cancel();
      await dir.delete(recursive: true);
    });
    expect(
      (await transport.request('Info:version', 'GET') as Map)['version'],
      libwalletPackageVersion,
    );
    final net = (await networks.list(
      testNet: false,
    )).firstWhere((network) => network.type == NetworkType.solana);
    await networks.update(net.id, rpc: rpc);
    await networks.setCurrent(net.id);
    final store = await StoreKeyApi(transport).create();
    final wallet = await WalletApi(transport).importPrivateKey(
      name: 'Public send fixture',
      privateKey: _seed,
      curve: 'ed25519',
      format: 'seed',
      keys: [KeyDescription.storeKey(store.publicKey)],
    );
    final account = await accounts.create(
      wallet: wallet.id,
      type: 'solana',
      index: 0,
      name: 'Public send fixture',
    );
    await accounts.setCurrent(account.id);
    final max = await transactions.maxSendable(
      from: account.id,
      to: _recipient,
      asset: 'solana.mainnet.NATIVE',
    );
    expect(max.max.value, BigInt.from(14834240));
    expect(max.reserved.map((item) => item.kind), contains('recipient_rent'));
    for (final asset in ['solana.mainnet.NATIVE', 'solana.mainnet.$_mint']) {
      final tx = UnsignedTransaction(
        type: 'transfer',
        from: account.id,
        to: _recipient,
        amount: Amount(BigInt.from(1000000), asset.endsWith('NATIVE') ? 9 : 6),
        asset: asset,
        network: net.id,
      );
      final validated = await transactions.validate(tx);
      expect(validated.raw, isNotEmpty);
      final simulation = await transactions.simulate(tx);
      expect(simulation.chain, 'solana');
      expect(simulation.willRevert, isFalse);
      expect(simulation.fee?.value, BigInt.from(5000));
      expect(simulation.effects, hasLength(1));
      expect(
        simulation.decodedMethod,
        asset.endsWith('NATIVE') ? 'native_transfer' : 'spl_transfer',
      );
      expect(
        simulation.warnings.map((warning) => warning.code),
        contains('recipient_new_account'),
      );
      failSimulation = true;
      expect((await transactions.simulate(tx)).willRevert, isTrue);
      failSimulation = false;
    }
    final methods = requests.map((body) => body['method']);
    expect(methods, contains('simulateTransaction'));
    expect(
      methods.where((method) => method.toString().startsWith('eth_')),
      isEmpty,
    );
    expect(methods, isNot(contains('sendTransaction')));
    for (final request in requests.where(
      (body) => body['method'] == 'simulateTransaction',
    )) {
      final config = (request['params'] as List)[1] as Map;
      expect(config['sigVerify'], false);
      expect(config['replaceRecentBlockhash'], true);
    }
  });
}
