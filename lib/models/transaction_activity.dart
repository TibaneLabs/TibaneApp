import '../constants/solana_constants.dart';
import 'package:libwallet/libwallet.dart' show Amount;

String formatActivityAmount(BigInt amount, int decimals, {int? maxDecimals}) {
  var units = amount;
  var precision = decimals;
  if (maxDecimals != null && decimals > maxDecimals) {
    final divisor = BigInt.from(10).pow(decimals - maxDecimals);
    final rounded = (amount.abs() + divisor ~/ BigInt.two) ~/ divisor;
    if (rounded == BigInt.zero && amount != BigInt.zero) {
      return '<${Amount(BigInt.one, maxDecimals)}';
    }
    units = amount.isNegative ? -rounded : rounded;
    precision = maxDecimals;
  }
  final value = Amount(units, precision).toString();
  return value.contains('.')
      ? value.replaceFirst(RegExp(r'\.?0+$'), '')
      : value;
}

enum ActivityKind { swap, sent, received, transaction }

class ActivityTokenChange {
  const ActivityTokenChange({
    required this.mint,
    required this.amount,
    required this.decimals,
    this.symbol,
    this.imageUrl,
  });

  final String mint;
  final BigInt amount;
  final int decimals;
  final String? symbol;
  final String? imageUrl;
}

class TransactionActivity {
  const TransactionActivity({
    required this.kind,
    required this.changes,
    required this.failed,
    required this.fee,
    this.sender,
    this.recipient,
    this.created,
  });

  final ActivityKind kind;
  final List<ActivityTokenChange> changes;
  final bool failed;
  final BigInt fee;
  final String? sender;
  final String? recipient;
  final DateTime? created;

  static TransactionActivity fromSolana(
    Map<String, dynamic> transaction,
    String owner,
  ) {
    final meta = transaction['meta'] as Map<String, dynamic>;
    final message =
        transaction['transaction']['message'] as Map<String, dynamic>;
    final keys = (message['accountKeys'] as List)
        .map((k) => k is String ? k : k['pubkey'] as String)
        .toList();
    final fee = BigInt.parse('${meta['fee'] ?? 0}');
    final failed = meta['err'] != null;
    final instructions = <Map>[
      ...((message['instructions'] as List?) ?? []).whereType<Map>(),
      for (final inner in (meta['innerInstructions'] as List?) ?? [])
        ...((inner['instructions'] as List?) ?? []).whereType<Map>(),
    ];
    final owners = <String, String>{};
    final ownedTokenIndices = <int>{};
    final deltas = <String, BigInt>{};
    final decimals = <String, int>{};
    for (final phase in ['preTokenBalances', 'postTokenBalances']) {
      for (final balance in (meta[phase] as List?) ?? []) {
        final index = balance['accountIndex'] as int;
        final accountOwner = balance['owner'] as String?;
        if (index < keys.length && accountOwner != null) {
          owners[keys[index]] = accountOwner;
        }
        if (accountOwner != owner) continue;
        ownedTokenIndices.add(index);
        final mint = balance['mint'] as String;
        final tokenAmount = balance['uiTokenAmount'];
        final amount = BigInt.parse(tokenAmount['amount'] as String);
        deltas[mint] =
            (deltas[mint] ?? BigInt.zero) +
            (phase == 'preTokenBalances' ? -amount : amount);
        decimals[mint] = tokenAmount['decimals'] as int;
      }
    }
    // Include newly created/closed temporary token accounts that may be absent
    // from one or both token-balance snapshots (notably wrapped SOL accounts).
    for (final instruction in instructions) {
      final parsed = instruction['parsed'];
      if (parsed is! Map || parsed['info'] is! Map) continue;
      final info = parsed['info'] as Map;
      final type = parsed['type'] as String? ?? '';
      if (type.startsWith('initializeAccount') ||
          instruction['program'] == 'spl-associated-token-account') {
        final account = info['account'] as String?;
        final accountOwner = (info['owner'] ?? info['wallet']) as String?;
        if (account != null && accountOwner != null) {
          owners[account] = accountOwner;
          final index = keys.indexOf(account);
          if (accountOwner == owner && index >= 0) ownedTokenIndices.add(index);
        }
      }
    }
    final pre = (meta['preBalances'] as List?) ?? [];
    final post = (meta['postBalances'] as List?) ?? [];
    final ownerIndex = keys.indexOf(owner);
    if (ownerIndex >= 0 &&
        ownerIndex < pre.length &&
        ownerIndex < post.length) {
      // Summing the owner's SOL and token-account lamports cancels rent
      // deposits/refunds. Wrapped SOL is included here, never counted twice.
      var nativeDelta = BigInt.zero;
      for (final index in {ownerIndex, ...ownedTokenIndices}) {
        if (index < pre.length && index < post.length) {
          nativeDelta +=
              BigInt.parse('${post[index]}') - BigInt.parse('${pre[index]}');
        }
      }
      if (ownerIndex == 0) nativeDelta += fee;
      deltas[wsolMint] = nativeDelta;
      decimals[wsolMint] = 9;
    }
    final changes = failed
        ? <ActivityTokenChange>[]
        : [
            for (final entry in deltas.entries)
              if (entry.value != BigInt.zero)
                ActivityTokenChange(
                  mint: entry.key,
                  amount: entry.value,
                  decimals: decimals[entry.key]!,
                  symbol: entry.key == wsolMint ? 'SOL' : null,
                ),
          ];
    final outgoing = changes.where((c) => c.amount.isNegative).toList();
    final incoming = changes.where((c) => !c.amount.isNegative).toList();
    final logs = ((meta['logMessages'] as List?) ?? []).whereType<String>();
    final swapInstruction = RegExp(
      r'^Program log: (Instruction: (Swap\w*|Route\w*|SharedAccountsRoute\w*|BuyExactQuoteIn|Sell\w*)|SwapEvent\b)',
    );
    final swapProgram = instructions.any(
      (i) => i['programId'] == 'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4',
    );
    final isSwap =
        outgoing.isNotEmpty &&
        incoming.isNotEmpty &&
        (swapProgram || logs.any(swapInstruction.hasMatch));
    final onlyTransfers =
        instructions.isNotEmpty &&
        instructions.every(
          (i) =>
              const {
                'system',
                'spl-token',
                'spl-token-2022',
                'spl-associated-token-account',
              }.contains(i['program']) ||
              const {
                'ComputeBudget111111111111111111111111111111',
                'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr',
              }.contains(i['programId']),
        );
    final kind = isSwap
        ? ActivityKind.swap
        : onlyTransfers && outgoing.isNotEmpty && incoming.isEmpty
        ? ActivityKind.sent
        : onlyTransfers && incoming.isNotEmpty && outgoing.isEmpty
        ? ActivityKind.received
        : ActivityKind.transaction;
    String? sender;
    String? recipient;
    if (isSwap) {
      sender = owner;
      recipient = owner;
    } else {
      for (final instruction in instructions) {
        final parsed = instruction['parsed'];
        if (parsed is! Map ||
            parsed['info'] is! Map ||
            !(parsed['type'] as String? ?? '').startsWith('transfer')) {
          continue;
        }
        final info = parsed['info'] as Map;
        final source = info['source'] as String?;
        final destination = info['destination'] as String?;
        final from = owners[source] ?? source;
        final to = owners[destination] ?? destination;
        if (from == owner || to == owner) {
          sender = from;
          recipient = to;
          break;
        }
      }
    }
    return TransactionActivity(
      kind: kind,
      changes: changes,
      failed: failed,
      fee: fee,
      sender: sender,
      recipient: recipient,
      created: transaction['blockTime'] is int
          ? DateTime.fromMillisecondsSinceEpoch(
              (transaction['blockTime'] as int) * 1000,
              isUtc: true,
            )
          : null,
    );
  }
}
