import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/models/transaction_activity.dart';

const owner = 'owner';
Map<String, Object> tokenBalance(
  int index,
  String mint,
  String amount, {
  String accountOwner = owner,
}) => {
  'accountIndex': index,
  'mint': mint,
  'owner': accountOwner,
  'uiTokenAmount': {'amount': amount, 'decimals': 6},
};

Map<String, dynamic> fixture({
  List<int> pre = const [10000000, 0, 0],
  List<int> post = const [7495000, 0, 0],
  List<Object> preTokens = const [],
  List<Object> postTokens = const [],
  List<Object> instructions = const [],
  List<String> logs = const [],
  Object? error,
  int fee = 5000,
}) => {
  'blockTime': 1792497600,
  'transaction': {
    'message': {
      'accountKeys': [owner, 'recipient', 'token-account'],
      'instructions': instructions,
    },
  },
  'meta': {
    'err': error,
    'fee': fee,
    'preBalances': pre,
    'postBalances': post,
    'preTokenBalances': preTokens,
    'postTokenBalances': postTokens,
    'logMessages': logs,
  },
};

void main() {
  test('compact activity values show at most four decimals', () {
    expect(
      formatActivityAmount(BigInt.from(994802149), 6, maxDecimals: 4),
      '994.8021',
    );
    expect(
      formatActivityAmount(BigInt.from(2444405), 9, maxDecimals: 4),
      '0.0024',
    );
    expect(
      formatActivityAmount(BigInt.from(10000000), 9, maxDecimals: 4),
      '0.01',
    );
    expect(formatActivityAmount(BigInt.one, 9, maxDecimals: 4), '<0.0001');
    expect(formatActivityAmount(BigInt.from(994802149), 6), '994.802149');
  });
  test('amount formatting preserves lamports and large integer precision', () {
    expect(formatActivityAmount(BigInt.one, 9), '0.000000001');
    expect(
      formatActivityAmount(BigInt.parse('99999999999999999'), 6),
      '99999999999.999999',
    );
    expect(formatActivityAmount(BigInt.from(1000000), 6), '1');
    expect(formatActivityAmount(BigInt.zero, 9), '0');
  });
  test('SOL swap excludes fee and new Token-2022 account rent', () {
    final tx = fixture(
      post: [5959822, 0, 1513840],
      fee: 26338,
      postTokens: [tokenBalance(2, 'token-2022', '994802149')],
      logs: ['Program log: Instruction: SwapTob'],
    );
    final activity = TransactionActivity.fromSolana(tx, owner);
    expect(activity.kind, ActivityKind.swap);
    expect(
      activity.changes.firstWhere((c) => c.mint == wsolMint).amount,
      BigInt.from(-2500000),
    );
    expect(
      activity.changes.firstWhere((c) => c.mint == 'token-2022').amount,
      BigInt.from(994802149),
    );
    expect(activity.sender, owner);
    expect(activity.recipient, owner);
    expect(activity.fee, BigInt.from(26338));
  });

  test('SPL sale excludes account rent refund from SOL proceeds', () {
    final activity = TransactionActivity.fromSolana(
      fixture(
        pre: [10000000, 0, 1513840],
        post: [14008840, 0, 0],
        preTokens: [tokenBalance(2, 'sold-token', '994802149')],
        logs: ['Program log: Instruction: SwapTob'],
      ),
      owner,
    );
    expect(activity.kind, ActivityKind.swap);
    expect(
      activity.changes.firstWhere((c) => c.mint == wsolMint).amount,
      BigInt.from(2500000),
    );
    expect(
      activity.changes.firstWhere((c) => c.mint == 'sold-token').amount,
      BigInt.from(-994802149),
    );
  });

  test('SPL to SPL does not add SOL fees as an input token', () {
    final activity = TransactionActivity.fromSolana(
      fixture(
        post: [9995000, 0, 0],
        preTokens: [tokenBalance(1, 'token-a', '10000000')],
        postTokens: [tokenBalance(2, 'token-b', '20000000')],
        logs: ['Program log: Instruction: Route'],
      ),
      owner,
    );
    expect(activity.kind, ActivityKind.swap);
    expect(activity.changes.map((c) => c.mint), ['token-a', 'token-b']);
  });

  test('ordinary SOL transfer keeps sender and recipient', () {
    final activity = TransactionActivity.fromSolana(
      fixture(
        instructions: [
          {
            'program': 'system',
            'parsed': {
              'type': 'transfer',
              'info': {
                'source': owner,
                'destination': 'recipient',
                'lamports': 2500000,
              },
            },
          },
        ],
      ),
      owner,
    );
    expect(activity.kind, ActivityKind.sent);
    expect(activity.sender, owner);
    expect(activity.recipient, 'recipient');
    expect(activity.changes.single.amount, BigInt.from(-2500000));
  });

  test('incoming SPL resolves recipient token account to its owner', () {
    final activity = TransactionActivity.fromSolana(
      fixture(
        pre: [10000000, 0, 1513840],
        post: [10000000, 0, 1513840],
        fee: 0,
        preTokens: [tokenBalance(2, 'token', '0')],
        postTokens: [tokenBalance(2, 'token', '99999999999999999')],
        instructions: [
          {
            'program': 'spl-token-2022',
            'parsed': {
              'type': 'transferChecked',
              'info': {
                'source': 'other-account',
                'destination': 'token-account',
              },
            },
          },
        ],
      ),
      owner,
    );
    expect(activity.kind, ActivityKind.received);
    expect(activity.recipient, owner);
    expect(activity.changes.single.amount, BigInt.parse('99999999999999999'));
  });

  test('failed transaction does not show successful movements', () {
    final activity = TransactionActivity.fromSolana(
      fixture(
        error: {
          'InstructionError': [0, 'test failure'],
        },
        postTokens: [tokenBalance(2, 'token', '100')],
        logs: ['Program log: Instruction: SwapTob'],
      ),
      owner,
    );
    expect(activity.failed, true);
    expect(activity.changes, isEmpty);
    expect(activity.kind, ActivityKind.transaction);
  });

  test('unknown contract is not automatically classified as Sent or Swap', () {
    final activity = TransactionActivity.fromSolana(
      fixture(
        postTokens: [tokenBalance(2, 'token', '100')],
        instructions: [
          {'programId': 'unknown-program'},
        ],
      ),
      owner,
    );
    expect(activity.kind, ActivityKind.transaction);
  });
}
