import 'dart:convert';

import 'package:libwallet/libwallet.dart' show Transaction;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/transaction_activity.dart';

const activityHistoryLimit = 9;

String activityTransactionId(Transaction tx) =>
    tx.hash?.isNotEmpty == true ? tx.hash! : tx.id;

List<Transaction> recentActivityTransactions(Iterable<Transaction> rows) {
  final unique = <String, Transaction>{};
  for (final tx in rows) {
    final id = activityTransactionId(tx);
    if (id.isNotEmpty) unique.putIfAbsent(id, () => tx);
  }
  return (unique.values.toList()..sort((a, b) {
        final date = (b.created ?? DateTime(1970)).compareTo(
          a.created ?? DateTime(1970),
        );
        return date != 0
            ? date
            : activityTransactionId(a).compareTo(activityTransactionId(b));
      }))
      .take(activityHistoryLimit)
      .toList();
}

class ActivityHistorySnapshot {
  const ActivityHistorySnapshot(this.transactions, this.activity);
  final List<Transaction> transactions;
  final Map<String, TransactionActivity> activity;
}

/// Public receipts only. Never persist signing keys, raw transactions or calldata.
class ActivityHistoryCache {
  static const _prefix = 'activity_history_v1_';
  Future<void> _writes = Future.value();
  static int _generation = 0;

  String _key(String scope) =>
      '$_prefix${base64Url.encode(utf8.encode(scope))}';

  Future<ActivityHistorySnapshot> read(String scope) async {
    final rows = <Transaction>[];
    final activity = <String, TransactionActivity>{};
    try {
      await _writes;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(scope));
      if (raw == null || raw.length > 1024 * 1024) {
        return const ActivityHistorySnapshot([], {});
      }
      final json = jsonDecode(raw);
      if (json is! List) return const ActivityHistorySnapshot([], {});
      for (final value in json.take(activityHistoryLimit)) {
        try {
          final row = Map<String, dynamic>.from(value as Map);
          final tx = Transaction.fromJson(
            Map<String, dynamic>.from(row['transaction'] as Map),
          );
          rows.add(tx);
          if (row['activity'] is Map) {
            activity[activityTransactionId(tx)] = _decodeActivity(
              row['activity'] as Map,
            );
          }
        } catch (_) {
          // One malformed receipt must not hide the remaining cached history.
        }
      }
    } catch (_) {
      // Storage is best-effort; live history remains usable if it is unavailable.
    }
    return ActivityHistorySnapshot(recentActivityTransactions(rows), activity);
  }

  Future<void> write(String scope, ActivityHistorySnapshot snapshot) {
    final generation = _generation;
    final encoded = jsonEncode([
      for (final tx in recentActivityTransactions(snapshot.transactions))
        {
          'transaction': {
            'id': tx.id,
            'type': tx.type,
            'asset': tx.asset,
            'from': tx.from,
            'to': tx.to,
            'gas': tx.gas,
            'nonce': tx.nonce,
            'hash': tx.hash,
            'network': tx.network,
            if (tx.created != null)
              'created': tx.created!.toUtc().toIso8601String(),
            if (tx.amount != null) 'amount': tx.amount!.toJson(),
            if (tx.fee != null) 'fee': tx.fee!.toJson(),
            if (tx.value != null) 'value': tx.value!.toJson(),
            if (tx.fiatAmount != null) 'fiat_amount': tx.fiatAmount!.toJson(),
            'fiat_currency': tx.fiatCurrency,
          },
          if (snapshot.activity[activityTransactionId(tx)] case final detail?)
            'activity': _encodeActivity(detail),
        },
    ]);
    return _enqueue(() async {
      if (generation != _generation) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(scope), encoded);
    });
  }

  Future<void> clear() {
    _generation++;
    return _enqueue(() async {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().where(
        (key) => key.startsWith(_prefix),
      )) {
        await prefs.remove(key);
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    _writes = _writes.then((_) => operation()).catchError((Object _) {});
    return _writes;
  }

  Map<String, dynamic> _encodeActivity(TransactionActivity a) => {
    'kind': a.kind.name,
    'failed': a.failed,
    'fee': a.fee.toString(),
    'sender': a.sender,
    'recipient': a.recipient,
    'created': a.created?.toUtc().toIso8601String(),
    'changes': [
      for (final c in a.changes)
        {
          'mint': c.mint,
          'amount': c.amount.toString(),
          'decimals': c.decimals,
          'symbol': c.symbol,
          'imageUrl': c.imageUrl,
        },
    ],
  };

  TransactionActivity _decodeActivity(Map a) => TransactionActivity(
    kind: ActivityKind.values.byName(a['kind'] as String),
    failed: a['failed'] as bool,
    fee: BigInt.parse(a['fee'] as String),
    sender: a['sender'] as String?,
    recipient: a['recipient'] as String?,
    created: a['created'] == null
        ? null
        : DateTime.parse(a['created'] as String),
    changes: [
      for (final c in (a['changes'] as List).take(100))
        ActivityTokenChange(
          mint: c['mint'] as String,
          amount: BigInt.parse(c['amount'] as String),
          decimals: c['decimals'] as int,
          symbol: c['symbol'] as String?,
          imageUrl: c['imageUrl'] as String?,
        ),
    ],
  );
}
