import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/password_rotation.dart';

Wallet _wallet(String id, List<String> types) => Wallet(
  id: id,
  name: id,
  curve: 'ed25519',
  threshold: 1,
  gen: 0,
  pubkey: 'public-$id',
  chaincode: '',
  created: DateTime(2026),
  modified: DateTime(2026),
  keys: [
    for (var i = 0; i < types.length; i++)
      WalletKey(
        id: '$id-key-$i',
        wallet: id,
        type: types[i],
        key: 'public-key-$i',
        gen: 0,
      ),
  ],
);

void main() {
  test(
    'D5 password changes use two Password authorizers and preserve the model',
    () async {
      final wallet = _wallet('d5', ['Password', 'Password', 'RemoteKey']);
      final plans = await preparePasswordRotation(
        wallets: [wallet],
        oldPassword: 'old',
        newPassword: 'new',
        passwordMatches: (_, password) async => password == 'old',
        readStoreSecret: (_, _, _) async =>
            fail('D5 must not request a device key'),
      );
      expect(plans.single.oldKeys.map((k) => k.type), ['Password', 'Password']);
      expect(plans.single.oldKeys.map((k) => k.id), ['d5-key-0', 'd5-key-1']);
      final newKeys = plans.single.newKeys('new', 'fresh-remote');
      expect(newKeys.map((k) => k.type), ['Password', 'Password', 'RemoteKey']);
      expect(newKeys.last.key, 'fresh-remote');
    },
  );

  test(
    'a partial group update can resume without rotating completed wallets again',
    () async {
      final wallets = [
        _wallet('a', ['Password', 'Password', 'RemoteKey']),
        _wallet('b', ['Password', 'Password', 'RemoteKey']),
      ];
      final passwords = {'a': 'old', 'b': 'old'};
      Future<List<PasswordRotationItem>> prepare() => preparePasswordRotation(
        wallets: wallets,
        oldPassword: 'old',
        newPassword: 'new',
        passwordMatches: (w, pw) async => passwords[w.id] == pw,
        readStoreSecret: (_, _, _) async => null,
      );
      final journal = <Set<String>>[];
      final changed = <String>[];
      await expectLater(
        executePasswordRotation(
          plans: await prepare(),
          newPassword: 'new',
          remoteKeyFor: (plan) async => 'fresh-${plan.wallet.id}',
          reshare: (plan, _) async {
            changed.add(plan.wallet.id);
            passwords[plan.wallet.id] = 'new';
            return plan.wallet;
          },
          persist: (wallet, _) async {
            if (wallet.id == 'b') {
              throw StateError('fixture interrupted persistence');
            }
          },
          journal: (ids) async => journal.add(Set.of(ids)),
        ),
        throwsA(isA<PasswordRotationIncomplete>()),
      );
      expect(changed, ['a', 'b']);
      expect(journal.last, {'b'});
      await executePasswordRotation(
        plans: await prepare(),
        newPassword: 'new',
        remoteKeyFor: (_) async =>
            fail('Already-updated wallets need no 2FA session'),
        reshare: (_, _) async =>
            fail('Already-updated wallets must not rotate again'),
        persist: (_, _) async {},
        journal: (ids) async => journal.add(Set.of(ids)),
      );
      expect(journal.last, isEmpty);
      expect(passwords.values, everyElement('new'));
    },
  );

  test('each wallet reshares on its own fresh RemoteKey session', () async {
    final wallets = [
      _wallet('ed', ['Password', 'Password', 'RemoteKey']),
      _wallet('secp', ['Password', 'Password', 'RemoteKey']),
    ];
    final plans = await preparePasswordRotation(
      wallets: wallets,
      oldPassword: 'old',
      newPassword: 'new',
      passwordMatches: (_, pw) async => pw == 'old',
      readStoreSecret: (_, _, _) async => null,
    );
    final events = <String>[];
    await executePasswordRotation(
      plans: plans,
      newPassword: 'new',
      remoteKeyFor: (plan) async {
        events.add('session:${plan.wallet.id}');
        return 'session-${plan.wallet.id}';
      },
      reshare: (plan, keys) async {
        final remote = keys.singleWhere((k) => k.type == 'RemoteKey');
        events.add('reshare:${plan.wallet.id}:${remote.key}');
        return plan.wallet;
      },
      persist: (_, _) async {},
      journal: (_) async {},
    );
    // One session per wallet, minted right before that wallet's reshare and
    // never reused for the next one.
    expect(events, [
      'session:ed',
      'reshare:ed:session-ed',
      'session:secp',
      'reshare:secp:session-secp',
    ]);
  });

  test('all old credentials are validated before the first mutation', () async {
    await expectLater(
      preparePasswordRotation(
        wallets: [
          _wallet('a', ['Password', 'Password', 'RemoteKey']),
          _wallet('b', ['Password', 'Password', 'RemoteKey']),
        ],
        oldPassword: 'old',
        newPassword: 'new',
        passwordMatches: (wallet, password) async =>
            wallet.id == 'a' && password == 'old',
        readStoreSecret: (_, _, _) async => null,
      ),
      throwsStateError,
    );
  });
}
