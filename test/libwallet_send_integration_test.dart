@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/services/solana_common.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

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

class _SendClient implements LibwalletClient {
  _SendClient(this.transactions, this.tokens);

  @override
  final TransactionApi transactions;
  @override
  final TokenApi tokens;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SendBackend extends LibwalletBackend {
  _SendBackend(this.client, this.currentNetwork, this.accountId);

  final LibwalletClient client;
  @override
  final Network currentNetwork;
  @override
  final String accountId;
  @override
  Future<LibwalletClient> ensureClient() async => client;
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
    var token2022 = false;
    final simulatedTokenPrograms = <bool>[];
    final token2022Bytes = base58Decode(token2022ProgramId);
    final mintData = Uint8List(82)..[44] = 6;
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(body);
      final method = body['method'];
      var incorrectProgram = false;
      if (token2022 && method == 'simulateTransaction') {
        final wire = base64Decode((body['params'] as List).first as String);
        final usesToken2022 =
            List.generate(
              wire.length - token2022Bytes.length + 1,
              (index) => index,
            ).any(
              (offset) => List.generate(
                token2022Bytes.length,
                (i) => i,
              ).every((i) => wire[offset + i] == token2022Bytes[i]),
            );
        simulatedTokenPrograms.add(usesToken2022);
        incorrectProgram = !usesToken2022;
      }
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
                  'owner': token2022 ? token2022ProgramId : splTokenProgramId,
                  'data':
                      ((body['params'] as List)[1] as Map)['encoding'] ==
                          'jsonParsed'
                      ? {
                          'program': token2022 ? 'spl-token-2022' : 'spl-token',
                          'parsed': {
                            'type': 'mint',
                            'info': {'decimals': 6, 'supply': '1000000'},
                          },
                        }
                      : [base64Encode(mintData), 'base64'],
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
            'err': incorrectProgram
                ? {
                    'InstructionError': [1, 'IncorrectProgramId'],
                  }
                : failSimulation
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

    final tokens = TokenApi(transport);
    final registered = await tokens.create(
      name: 'Token-2022 fixture',
      symbol: 'T22',
      address: _mint,
      decimals: 6,
      network: net.id,
      type: 'spl-token',
    );
    token2022 = true;
    final backend = _SendBackend(
      _SendClient(transactions, tokens),
      net,
      account.id,
    );
    addTearDown(backend.dispose);
    final repaired = await backend.simulateSend(
      to: _recipient,
      amount: Amount(BigInt.from(1000000), 6),
      asset: 'solana.mainnet.$_mint',
    );
    expect(repaired.willRevert, isFalse);
    expect(simulatedTokenPrograms, [false, true]);
    expect((await tokens.get(registered.id)).type, 'spl-token-2022');

    failSimulation = true;
    final blocked = await backend.simulateSend(
      to: _recipient,
      amount: Amount(BigInt.from(1000000), 6),
      asset: 'solana.mainnet.$_mint',
    );
    expect(blocked.willRevert, isTrue);
    expect(simulatedTokenPrograms, [false, true, true]);

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
