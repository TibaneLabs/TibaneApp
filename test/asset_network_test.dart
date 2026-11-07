import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/asset_network.dart';

void main() {
  final now = DateTime.utc(2026);
  final ethereum = Network(
    id: 'net-ethereum',
    type: NetworkType.evm,
    chainId: '1',
    name: 'Ethereum',
    rpc: '',
    currencySymbol: 'ETH',
    currencyDecimals: 18,
    blockExplorer: '',
    testNet: false,
    priority: 0,
    created: now,
    updated: now,
  );

  Asset asset(String network) => Asset(
    id: '',
    key: 'evm.1.NATIVE',
    name: 'Ethereum',
    symbol: 'ETH',
    amount: Amount(BigInt.one, 18),
    type: 'fungible',
    network: network,
    testNet: false,
    created: now,
    updated: now,
  );

  test('accepts libwallet network ID and canonical chain key', () {
    expect(assetBelongsToNetwork(asset('net-ethereum'), ethereum), isTrue);
    expect(assetBelongsToNetwork(asset('evm.1'), ethereum), isTrue);
  });

  test('rejects assets from other networks', () {
    expect(assetBelongsToNetwork(asset('evm.137'), ethereum), isFalse);
    expect(assetBelongsToNetwork(asset('net-polygon'), ethereum), isFalse);
    expect(assetBelongsToNetwork(asset(''), ethereum), isFalse);
  });
}
