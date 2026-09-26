import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show Wallet;
import 'package:tibaneapp/screens/wallet/widgets/account_switcher_view_model.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';

UnifiedAccount _acct({
  required String id,
  required String chain,
  String? walletId,
  int? index,
  bool main = false,
  AccountBackend backend = AccountBackend.inapp,
}) => UnifiedAccount(
  backend: backend,
  chain: chain,
  address: 'addr-$id',
  label: id,
  accountId: id,
  walletId: walletId,
  accountIndex: index,
  isMainWalletContext: main,
);

Wallet _wallet({required String id, String curve = 'ed25519'}) => Wallet(
  id: id,
  name: 'W-$id',
  curve: curve,
  threshold: 1,
  gen: 0,
  pubkey: '',
  chaincode: '',
  created: DateTime(2020),
  modified: DateTime(2020),
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

    test('in-app accounts with no logical wallet fall into the unnamed group', () {
      final groups = buildAccountGroups(
        accounts: [_acct(id: 'orphan', chain: 'solana', walletId: 'ghost', main: true)],
        wallets: const [], // no logical wallets → orphan is a leftover
        unnamedLabel: 'Unnamed',
      );
      expect(groups, hasLength(1));
      expect(groups.single.walletName, 'Unnamed');
      expect(groups.single.mainAccounts.map((a) => a.id).toList(), ['orphan']);
    });
  });
}
