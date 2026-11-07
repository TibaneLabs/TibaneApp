import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/send_transaction.dart';

void main() {
  final bitcoin = Network(
    id: 'btc',
    type: NetworkType.bitcoin,
    chainId: 'bitcoin',
    name: 'Bitcoin',
    rpc: '',
    currencySymbol: 'BTC',
    currencyDecimals: 8,
    blockExplorer: '',
    testNet: false,
    priority: 0,
    created: DateTime(2026),
    updated: DateTime(2026),
  );
  test(
    'Bitcoin MAX preserves exact UTXOs and fee rate in preflight and signing',
    () {
      final plan = MaxSendableResult(
        chain: 'bitcoin',
        max: Amount(BigInt.from(9000), 8),
        balance: Amount(BigInt.from(10000), 8),
        fee: Amount(BigInt.from(1000), 8),
        bitcoinUtxos: ['fixture:0', 'fixture:1'],
        bitcoinFeeRate: 12,
      );
      for (final simulation in [true, false]) {
        final tx = buildSendTransaction(
          network: bitcoin,
          accountId: 'account',
          senderAddress: 'sender',
          recipient: 'recipient',
          amount: plan.max,
          asset: 'bitcoin.bitcoin.NATIVE',
          simulation: simulation,
          maxPlan: plan,
        );
        expect(tx.utxos, plan.bitcoinUtxos);
        expect(tx.bitcoinFeeRate, 12);
        expect(tx.type, 'bitcoin_transfer');
      }
      expect(
        () => buildSendTransaction(
          network: bitcoin,
          accountId: 'account',
          senderAddress: 'sender',
          recipient: 'recipient',
          amount: Amount(BigInt.from(9001), 8),
          asset: 'bitcoin.bitcoin.NATIVE',
          simulation: false,
          maxPlan: plan,
        ),
        throwsStateError,
      );
    },
  );
}
