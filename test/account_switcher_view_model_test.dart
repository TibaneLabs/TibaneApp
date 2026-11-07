import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show Wallet;
import 'package:tibaneapp/screens/wallet/widgets/account_switcher_view_model.dart';
import 'package:tibaneapp/services/wallet/logical_wallet.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';

UnifiedAccount _acct({
  required String id,
  required String chain,
  String? walletId,
  int? index,
  bool main = false,
  DateTime? createdAt,
  AccountBackend backend = AccountBackend.inapp,
}) => UnifiedAccount(
  backend: backend,
  chain: chain,
  address: 'addr-$id',
  label: id,
  accountId: id,
  walletId: walletId,
  accountIndex: index,
  createdAt: createdAt,
  isMainWalletContext: main,
);

Wallet _wallet({
  required String id,
  String curve = 'ed25519',
  String? name,
  DateTime? created,
}) => Wallet(
  id: id,
  name: name ?? 'W-$id',
  curve: curve,
  threshold: 1,
  gen: 0,
  pubkey: '',
  chaincode: '',
  created: created ?? DateTime(2020),
  modified: created ?? DateTime(2020),
  keys: const [],
);

void main() {
  group('accountTypeForChain', () {
    test('bitcoin-family chains ride the ethereum account', () {
      for (final c in ['bitcoin', 'bitcoin-cash', 'dogecoin', 'litecoin']) {
        expect(accountTypeForChain(c), 'ethereum');
      }
    });
    test('non-bitcoin chains are their own type', () {
      expect(accountTypeForChain('solana'), 'solana');
      expect(accountTypeForChain('ethereum'), 'ethereum');
    });
  });

  group('initialChain', () {
    test('bitcoin-family preferred maps to ethereum when available', () {
      expect(initialChain(['solana', 'ethereum'], 'litecoin'), 'ethereum');
    });
    test('preferred is kept when creatable', () {
      expect(initialChain(['solana', 'ethereum'], 'solana'), 'solana');
    });
    test('falls back to first when preferred is absent or null', () {
      expect(initialChain(['solana', 'ethereum'], 'polkadot'), 'solana');
      expect(initialChain(['ethereum'], null), 'ethereum');
    });
  });

  group('creationChains', () {
    test('offers Solana and Ethereum account creation', () {
      final group = LogicalWallet([
        _wallet(id: 'sol', curve: 'ed25519'),
        _wallet(id: 'evm', curve: 'secp256k1'),
      ]);
      expect(creationChains(group), ['solana', 'ethereum']);
    });
  });

  group('compareAccountsForSwitcher', () {
    test('orders by chain, then index, then id', () {
      final accounts = [
        _acct(id: 'b1', chain: 'bitcoin'),
        _acct(id: 'e1', chain: 'ethereum', index: 1),
        _acct(id: 'e0', chain: 'ethereum', index: 0),
        _acct(id: 's1', chain: 'solana'),
      ]..sort(compareAccountsForSwitcher);
      expect(accounts.map((a) => a.id).toList(), ['s1', 'e0', 'e1', 'b1']);
    });
    test('unknown chains sort last', () {
      final accounts = [
        _acct(id: 'x', chain: 'mystery'),
        _acct(id: 's', chain: 'solana'),
      ]..sort(compareAccountsForSwitcher);
      expect(accounts.first.id, 's');
    });
  });

  group('buildAccountGroups', () {
    test('added accounts follow creation time across networks and imports', () {
      final nativeSol = _acct(
        id: 'native-sol',
        chain: 'solana',
        walletId: 'sol',
        main: true,
      );
      final nativeEth = _acct(
        id: 'native-eth',
        chain: 'ethereum',
        walletId: 'eth',
        main: true,
      );
      final addedEth = _acct(
        id: 'first-added',
        chain: 'ethereum',
        walletId: 'eth',
        index: 2,
        createdAt: DateTime.utc(2026, 11, 1),
      );
      final imported = _acct(
        id: 'second-added',
        chain: 'solana',
        walletId: 'imported',
        index: 0,
        createdAt: DateTime.utc(2026, 11, 2),
      );
      final addedSol = _acct(
        id: 'third-added',
        chain: 'solana',
        walletId: 'sol',
        index: 1,
        createdAt: DateTime.utc(2026, 11, 3),
      );
      final groups = buildAccountGroups(
        accounts: [addedSol, nativeEth, imported, nativeSol, addedEth],
        wallets: [
          _wallet(id: 'sol'),
          _wallet(id: 'eth', curve: 'secp256k1'),
          _wallet(id: 'imported'),
        ],
        walletGroups: const {'sol': 'main', 'eth': 'main'},
        attachedWalletParents: const {'imported': 'sol'},
        unnamedLabel: 'Unnamed',
      );
      expect(groups, hasLength(1));
      expect(groups.single.mainAccounts, [nativeSol, nativeEth]);
      expect(groups.single.additionalAccounts, [addedEth, imported, addedSol]);
    });

    test('unnamed group also sorts added accounts by creation time', () {
      final groups = buildAccountGroups(
        accounts: [
          _acct(
            id: 'later-sol',
            chain: 'solana',
            createdAt: DateTime.utc(2026, 11, 2),
          ),
          _acct(
            id: 'earlier-eth',
            chain: 'ethereum',
            createdAt: DateTime.utc(2026, 11, 1),
          ),
        ],
        wallets: const [],
        unnamedLabel: 'Unnamed',
      );
      expect(groups.single.additionalAccounts.map((a) => a.id), [
        'earlier-eth',
        'later-sol',
      ]);
    });

    test(
      'tied and missing dates preserve source order without chain sorting',
      () {
        for (final created in [null, DateTime.utc(2026)]) {
          final accounts = [
            _acct(id: 'eth', chain: 'ethereum', createdAt: created),
            _acct(id: 'sol', chain: 'solana', createdAt: created),
          ];
          final groups = buildAccountGroups(
            accounts: accounts,
            wallets: const [],
            unnamedLabel: 'Unnamed',
          );
          expect(groups.single.additionalAccounts, accounts);
        }
      },
    );

    test('splits main vs additional, sorts, and excludes MWA accounts', () {
      final accounts = [
        _acct(id: 'sol', chain: 'solana', walletId: 'w1', main: true),
        _acct(id: 'btc', chain: 'bitcoin', walletId: 'w1', main: true),
        _acct(id: 'extra', chain: 'solana', walletId: 'w1', index: 1),
        _acct(id: 'mwa', chain: 'solana', backend: AccountBackend.mwa),
      ];
      final groups = buildAccountGroups(
        accounts: accounts,
        wallets: [_wallet(id: 'w1')],
        unnamedLabel: 'Unnamed',
      );
      expect(groups, hasLength(1));
      expect(groups.single.id, 'w1');
      // main accounts are chain-sorted (solana before bitcoin).
      expect(groups.single.mainAccounts.map((a) => a.id).toList(), [
        'sol',
        'btc',
      ]);
      expect(groups.single.additionalAccounts.map((a) => a.id).toList(), [
        'extra',
      ]);
      final allIds = [
        ...groups.single.mainAccounts,
        ...groups.single.additionalAccounts,
      ].map((a) => a.id);
      expect(allIds.contains('mwa:addr-mwa'), isFalse);
    });

    test('keeps interleaved accounts inside their logical wallet groups', () {
      final firstCreated = DateTime(2020, 1, 1, 12);
      final secondCreated = DateTime(2020, 1, 2, 12);
      final wallets = [
        _wallet(id: 'first-sol', name: 'First', created: firstCreated),
        _wallet(
          id: 'first-evm',
          curve: 'secp256k1',
          name: 'First',
          created: firstCreated.add(const Duration(seconds: 1)),
        ),
        _wallet(id: 'second-sol', name: 'Second', created: secondCreated),
        _wallet(
          id: 'second-evm',
          curve: 'secp256k1',
          name: 'Second',
          created: secondCreated.add(const Duration(seconds: 1)),
        ),
      ];
      final groups = buildAccountGroups(
        accounts: [
          _acct(
            id: 'first-eth',
            chain: 'ethereum',
            walletId: 'first-evm',
            main: true,
          ),
          _acct(
            id: 'second-sol',
            chain: 'solana',
            walletId: 'second-sol',
            main: true,
          ),
          _acct(
            id: 'first-sol',
            chain: 'solana',
            walletId: 'first-sol',
            main: true,
          ),
          _acct(
            id: 'second-eth',
            chain: 'ethereum',
            walletId: 'second-evm',
            main: true,
          ),
        ],
        wallets: wallets,
        walletGroups: const {
          'first-sol': 'first',
          'first-evm': 'first',
          'second-sol': 'second',
          'second-evm': 'second',
        },
        unnamedLabel: 'Unnamed',
      );

      expect(groups.map((group) => group.walletName), ['First', 'Second']);
      expect(groups[0].mainAccounts.map((account) => account.id), [
        'first-sol',
        'first-eth',
      ]);
      expect(groups[1].mainAccounts.map((account) => account.id), [
        'second-sol',
        'second-eth',
      ]);
    });

    test('shows an attached technical wallet as an additional account', () {
      final groups = buildAccountGroups(
        accounts: [
          _acct(id: 'main', chain: 'solana', walletId: 'main-sol', main: true),
          _acct(
            id: 'extra',
            chain: 'solana',
            walletId: 'extra-sol',
            main: false,
          ),
        ],
        wallets: [
          _wallet(id: 'main-sol', name: 'Main'),
          _wallet(id: 'extra-sol', name: 'Main', created: DateTime(2020, 2)),
        ],
        unnamedLabel: 'Unnamed',
        attachedWalletParents: const {'extra-sol': 'main-sol'},
      );

      expect(groups, hasLength(1));
      expect(groups.single.mainAccounts.map((account) => account.id), ['main']);
      expect(groups.single.additionalAccounts.map((account) => account.id), [
        'extra',
      ]);
    });

    test(
      'in-app accounts with no logical wallet fall into the unnamed group',
      () {
        final groups = buildAccountGroups(
          accounts: [
            _acct(id: 'orphan', chain: 'solana', walletId: 'ghost', main: true),
          ],
          wallets: const [], // no logical wallets → orphan is a leftover
          unnamedLabel: 'Unnamed',
        );
        expect(groups, hasLength(1));
        expect(groups.single.id, 'unmatched-in-app-accounts');
        expect(groups.single.walletName, 'Unnamed');
        expect(groups.single.mainAccounts.map((a) => a.id).toList(), [
          'orphan',
        ]);
      },
    );
  });
}
