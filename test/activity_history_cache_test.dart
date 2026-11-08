import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/models/transaction_activity.dart';
import 'package:tibaneapp/services/activity_history_cache.dart';

Transaction _tx(int n, {String? id}) => Transaction(
  id: id ?? 'row-$n',
  type: 'transfer',
  asset: 'solana.mainnet.NATIVE',
  from: 'public-owner',
  to: 'public-recipient',
  gas: 0,
  nonce: 0,
  hash: 'public-signature-$n',
  network: 'mainnet',
  created: DateTime.utc(2026, 11, 8, 0, n),
  amount: Amount(BigInt.parse('123456789123456789'), 9),
  raw: 'DO-NOT-CACHE-RAW',
  data: 'DO-NOT-CACHE-CALLDATA',
);

TransactionActivity _detail() => TransactionActivity(
  kind: ActivityKind.swap,
  failed: false,
  fee: BigInt.from(5000),
  sender: 'public-owner',
  recipient: 'public-owner',
  created: DateTime.utc(2026, 11, 8),
  changes: [
    ActivityTokenChange(
      mint: 'public-mint',
      amount: BigInt.parse('-999999999999999999999'),
      decimals: 9,
      symbol: 'TEST',
      imageUrl: 'https://example.com/token.png',
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'stores only nine newest receipts and deduplicates by chain signature',
    () async {
      final cache = ActivityHistoryCache();
      await cache.write(
        'account-a:solana',
        ActivityHistorySnapshot([
          for (var n = 0; n < 12; n++) _tx(n),
          _tx(11, id: 'different-local-id'),
        ], {}),
      );
      final restored = await ActivityHistoryCache().read('account-a:solana');
      expect(restored.transactions.map((tx) => tx.hash), [
        for (var n = 11; n >= 3; n--) 'public-signature-$n',
      ]);
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(prefs.getKeys().single)!;
      expect(data, isNot(contains('DO-NOT-CACHE')));
      expect(jsonDecode(data), hasLength(9));
      expect(
        restored.transactions.first.amount!.value.toString(),
        '123456789123456789',
      );
      expect(restored.transactions.first.raw, isNull);
      expect(restored.transactions.first.data, isNull);
    },
  );

  test(
    'receipt details survive a new cache instance without losing precision',
    () async {
      await ActivityHistoryCache().write(
        'account-a:solana',
        ActivityHistorySnapshot([_tx(1)], {'public-signature-1': _detail()}),
      );
      final restored = await ActivityHistoryCache().read('account-a:solana');
      final detail = restored.activity['public-signature-1']!;
      expect(detail.kind, ActivityKind.swap);
      expect(detail.fee, BigInt.from(5000));
      expect(detail.changes.single.amount.toString(), '-999999999999999999999');
      expect(detail.changes.single.symbol, 'TEST');
      expect(detail.sender, 'public-owner');
    },
  );

  test('account and network scopes remain isolated', () async {
    final cache = ActivityHistoryCache();
    await cache.write(
      'account-a:solana',
      ActivityHistorySnapshot([_tx(1)], {}),
    );
    await cache.write(
      'account-b:solana',
      ActivityHistorySnapshot([_tx(2)], {}),
    );
    expect(
      (await cache.read('account-a:solana')).transactions.single.id,
      'row-1',
    );
    expect(
      (await cache.read('account-b:solana')).transactions.single.id,
      'row-2',
    );
    expect((await cache.read('account-a:ethereum')).transactions, isEmpty);
  });

  test(
    'merge retains older cached receipts when the provider returns only one',
    () {
      final rows = recentActivityTransactions([
        _tx(11),
        ...[for (var n = 10; n >= 2; n--) _tx(n)],
      ]);
      expect(rows, hasLength(9));
      expect(rows.first.id, 'row-11');
      expect(rows.last.id, 'row-3');
      expect(
        recentActivityTransactions([...rows, _tx(1)]).map((tx) => tx.id),
        rows.map((tx) => tx.id),
      );
    },
  );

  test('corrupt cache fails closed without blocking live history', () async {
    final cache = ActivityHistoryCache();
    await cache.write('scope', ActivityHistorySnapshot([_tx(1)], {}));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefs.getKeys().single, '{invalid json');
    expect((await cache.read('scope')).transactions, isEmpty);
    await cache.write('scope', ActivityHistorySnapshot([_tx(2)], {}));
    expect((await cache.read('scope')).transactions.single.id, 'row-2');
  });

  test(
    'reset removes public snapshots and invalidates queued writes only',
    () async {
      final cache = ActivityHistoryCache();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('locale', 'pt');
      final pending = cache.write(
        'scope',
        ActivityHistorySnapshot([_tx(1)], {}),
      );
      await cache.clear();
      await pending;
      expect((await cache.read('scope')).transactions, isEmpty);
      expect(prefs.getKeys(), {'locale'});
      await cache.write('scope', ActivityHistorySnapshot([_tx(2)], {}));
      expect((await cache.read('scope')).transactions.single.id, 'row-2');
    },
  );
}
