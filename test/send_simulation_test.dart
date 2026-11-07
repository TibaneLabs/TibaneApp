import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

class _Transport implements Transport {
  Object? error;
  int transientMaxFailures = 0;
  final calls = <String>[];
  Map<String, dynamic>? transaction;

  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    calls.add(path);
    transaction = params;
    if (error != null) throw error!;
    if (path == 'Transaction:maxSendable') {
      if (transientMaxFailures-- > 0) {
        throw StateError('Resource temporarily unavailable (os error 35)');
      }
      return {
        'chain': 'solana',
        'max': {'v': '1234567', 'e': 9},
        'balance': {'v': '2125447', 'e': 9},
        'fee': {'v': '5000', 'e': 9},
      };
    }
    return {
      'chain': 'solana',
      'willRevert': true,
      'revertReason': 'insufficient funds',
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  _Client(Transport transport) : transactions = TransactionApi(transport);
  @override
  final TransactionApi transactions;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(this.client);
  final LibwalletClient client;
  @override
  String? get accountId => 'source-account';
  @override
  Future<LibwalletClient> ensureClient() async => client;
  @override
  Network get currentNetwork => Network(id: 'solana', type: NetworkType.solana,
    chainId: 'mainnet', name: 'Solana', rpc: '', currencySymbol: 'SOL', currencyDecimals: 9,
    blockExplorer: '', testNet: false, priority: 0, created: DateTime(2026), updated: DateTime(2026));
}

void main() {
  late _Transport transport;
  late _Backend backend;
  setUp(() {
    transport = _Transport();
    backend = _Backend(_Client(transport));
  });
  tearDown(() => backend.dispose());

  test(
    'native MAX retries temporary read errors without changing the contract',
    () async {
      transport.transientMaxFailures = 2;
      final result = await backend.maxSendable(
        asset: 'solana.mainnet.NATIVE',
        to: 'recipient',
      );
      expect(result.max.value, BigInt.from(1234567));
      expect(transport.calls, List.filled(3, 'Transaction:maxSendable'));
      expect(transport.transaction!['from'], 'source-account');
    },
  );

  test('native MAX does not retry a permanent error', () async {
    transport.error = StateError('Insufficient funds');
    await expectLater(backend.maxSendable(), throwsStateError);
    expect(transport.calls, ['Transaction:maxSendable']);
  });

  test(
    'send uses official simulation and preserves a failed preview',
    () async {
      final simulation = await backend.simulateSend(
        to: 'recipient',
        amount: Amount(BigInt.from(1000000), 9),
        asset: 'solana.mainnet.NATIVE',
      );
      expect(transport.calls, ['Transaction:simulate']);
      expect(transport.transaction!['from'], 'source-account');
      expect(transport.transaction!['asset'], 'solana.mainnet.NATIVE');
      expect(simulation.willRevert, isTrue);
      expect(simulation.revertReason, 'insufficient funds');
    },
  );

  test('simulation exceptions must not become successful previews', () async {
    transport.error = StateError('RPC unavailable');
    await expectLater(
      backend.simulateSend(
        to: 'recipient',
        amount: Amount(BigInt.from(1000000), 6),
        asset: 'solana.mainnet.fixture-mint',
      ),
      throwsStateError,
    );
    expect(transport.calls, ['Transaction:simulate']);
  });
}
