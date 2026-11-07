import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

Network _network(NetworkType type) => Network(
  id: type == NetworkType.evm ? 'eth-mainnet' : 'sol-mainnet',
  type: type,
  chainId: type == NetworkType.evm ? '1' : 'mainnet',
  name: 'Fixture',
  rpc: '',
  currencySymbol: type == NetworkType.evm ? 'ETH' : 'SOL',
  currencyDecimals: type == NetworkType.evm ? 18 : 9,
  blockExplorer: '',
  testNet: false,
  priority: 0,
  created: DateTime(2026),
  updated: DateTime(2026),
);

class _Transport implements Transport {
  final pages = <List<Map<String, dynamic>>>[];
  final calls = <Map<String, dynamic>>[];
  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    calls.add(params!);
    return pages.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  _Client(this.transport);
  final _Transport transport;
  @override
  late final transactions = TransactionApi(transport);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(this.client, this.network);
  final _Client client;
  final Network network;
  @override
  Future<LibwalletClient> ensureClient() async => client;
  @override
  Network get currentNetwork => network;
}

Map<String, dynamic> _tx(String id, String from, String network, int hour) => {
  'id': id,
  'from': from,
  'to': 'other',
  'network': network,
  'asset': network.startsWith('sol') ? 'solana.mainnet.NATIVE' : 'evm.1.NATIVE',
  'created': DateTime(2026, 1, 1, hour).toIso8601String(),
};
void main() {
  test(
    'history scopes both network and EVM address and continues after a partial match',
    () async {
      final transport = _Transport()
        ..pages.addAll([
          [
            _tx('eth-1', '0xABC', 'eth-mainnet', 6),
            _tx('bsc', '0xABC', 'evm.56', 5),
          ],
          [
            _tx('eth-2', '0xabc', 'evm.1', 4),
            _tx('other', '0xdef', 'evm.1', 3),
          ],
        ]);
      final backend = _Backend(_Client(transport), _network(NetworkType.evm));
      addTearDown(backend.dispose);
      final page = await backend.getTransactionPage(
        limit: 2,
        forAddress: '0xAbC',
      );
      expect(page.items.map((t) => t.id), ['eth-1', 'eth-2']);
      expect(page.hasMore, true);
      expect(page.before, DateTime(2026, 1, 1, 3).toIso8601String());
      expect(transport.calls, hasLength(2));
      expect(transport.calls.first['Network'], 'eth-mainnet');
    },
  );
  test(
    'Solana history never treats differently cased addresses as the same account',
    () async {
      final transport = _Transport()
        ..pages.add([
          _tx('exact', 'AbcDEf', 'sol-mainnet', 6),
          _tx('different', 'abcdef', 'sol-mainnet', 5),
        ]);
      final backend = _Backend(
        _Client(transport),
        _network(NetworkType.solana),
      );
      addTearDown(backend.dispose);
      final page = await backend.getTransactionPage(
        limit: 50,
        forAddress: 'AbcDEf',
      );
      expect(page.items.map((t) => t.id), ['exact']);
      expect(page.hasMore, false);
    },
  );
}
