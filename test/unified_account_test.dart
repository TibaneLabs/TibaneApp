import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show Account, Wallet;
import 'package:tibaneapp/services/wallet/unified_account.dart';

/// Unit tests for the account-centric model (Atonline-parity Phase 4b-1). The
/// builder + resolvers are pure top-level functions, so they're verified here
/// without a libwallet client; `WalletService.refreshAccounts/setCurrentAccount`
/// (which drive backend switching) are device-verified.

Account _acct({
  required String id,
  required String wallet,
  String name = 'Account 1',
  String type = 'solana',
  String address = 'addr',
}) => Account(
  id: id,
  wallet: wallet,
  name: name,
  index: 0,
  type: type,
  path: '',
  address: address,
  uri: '',
  pubkey: '',
  chaincode: '',
  created: DateTime(2020),
  updated: DateTime(2020),
);

Wallet _wallet({
  required String id,
  String name = 'Wallet 1',
  String curve = 'ed25519',
}) => Wallet(
  id: id,
  name: name,
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
  group('buildUnifiedAccounts', () {
    test('in-app account: label "name — walletName", ids + chain mapped', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [
          _acct(id: 'acc1', wallet: 'w1', name: 'Main', address: 'SoLaddr'),
        ],
        walletsById: {'w1': _wallet(id: 'w1', name: 'My Wallet')},
      );
      expect(out, hasLength(1));
      final a = out.single;
      expect(a.backend, AccountBackend.inapp);
      expect(a.isInApp, isTrue);
      expect(a.label, 'Main — My Wallet');
      expect(a.chain, 'solana');
      expect(a.isSolana, isTrue);
      expect(a.address, 'SoLaddr');
      expect(a.walletId, 'w1');
      expect(a.accountId, 'acc1');
      expect(a.curve, 'ed25519');
      expect(a.id, 'acc1');
    });

    test('missing wallet in map → label falls back to the account name', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [_acct(id: 'acc1', wallet: 'w-missing', name: 'Main')],
        walletsById: const {},
      );
      expect(out.single.label, 'Main');
      expect(out.single.curve, isNull);
    });

    test('MWA appended only with an address; always Solana; mwa: id', () {
      expect(
        buildUnifiedAccounts(inappAccounts: const [], walletsById: const {}),
        isEmpty,
      );
      final withMwa = buildUnifiedAccounts(
        inappAccounts: const [],
        walletsById: const {},
        mwaAddress: 'MwaPubkey',
      );
      expect(withMwa, hasLength(1));
      final m = withMwa.single;
      expect(m.backend, AccountBackend.mwa);
      expect(m.isMwa, isTrue);
      expect(m.chain, 'solana');
      expect(m.isSolana, isTrue);
      expect(m.address, 'MwaPubkey');
      expect(m.label, 'External (Seed Vault)');
      expect(m.id, 'mwa:MwaPubkey');
    });

    test('empty mwaAddress is treated as no MWA', () {
      expect(
        buildUnifiedAccounts(
          inappAccounts: const [],
          walletsById: const {},
          mwaAddress: '',
        ),
        isEmpty,
      );
    });

    test('in-app first then MWA last; multi-wallet, multi-chain', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [
          _acct(id: 'a1', wallet: 'w1', name: 'A1', type: 'solana'),
          _acct(id: 'a2', wallet: 'w2', name: 'A2', type: 'ethereum'),
        ],
        walletsById: {
          'w1': _wallet(id: 'w1', name: 'W1'),
          'w2': _wallet(id: 'w2', name: 'W2', curve: 'secp256k1'),
        },
        mwaAddress: 'M',
      );
      expect(out.map((a) => a.id).toList(), ['a1', 'a2', 'mwa:M']);
      expect(out[1].chain, 'ethereum');
      expect(out[1].isSolana, isFalse);
      expect(out[1].curve, 'secp256k1');
      expect(out.last.backend, AccountBackend.mwa);
    });
  });

  group('pickNextAccount', () {
    final list = buildUnifiedAccounts(
      inappAccounts: [
        _acct(id: 'a1', wallet: 'w1'),
        _acct(id: 'a2', wallet: 'w1'),
      ],
      walletsById: {'w1': _wallet(id: 'w1')},
    );

    test('returns the first account whose id != removed', () {
      expect(pickNextAccount(list, 'a1')!.id, 'a2');
      expect(pickNextAccount(list, 'a2')!.id, 'a1');
    });

    test('null when the only account is the removed one', () {
      expect(pickNextAccount([list.first], 'a1'), isNull);
    });

    test('null on empty', () {
      expect(pickNextAccount(const [], 'x'), isNull);
    });
  });

  group('resolvePersistedAccount', () {
    final inapp1 = _acct(id: 'a1', wallet: 'w1', name: 'A1');
    final wallets = {'w1': _wallet(id: 'w1', name: 'W1')};

    test('savedId present → returns the matching account', () {
      final list = buildUnifiedAccounts(
        inappAccounts: [inapp1],
        walletsById: wallets,
        mwaAddress: 'M',
      );
      expect(resolvePersistedAccount(accounts: list, savedId: 'mwa:M')!.id,
          'mwa:M');
    });

    test('saved MWA gone (Seed Vault disconnected) → first in-app fallback', () {
      // Saved was the MWA account, but this launch only has in-app accounts.
      final list = buildUnifiedAccounts(
        inappAccounts: [inapp1],
        walletsById: wallets,
      );
      final r = resolvePersistedAccount(accounts: list, savedId: 'mwa:M');
      expect(r!.id, 'a1');
      expect(r.isInApp, isTrue);
    });

    test('savedId null → first in-app', () {
      final list = buildUnifiedAccounts(
        inappAccounts: [inapp1],
        walletsById: wallets,
        mwaAddress: 'M',
      );
      expect(resolvePersistedAccount(accounts: list, savedId: null)!.id, 'a1');
    });

    test('only MWA available → returns it even with null saved', () {
      final list = buildUnifiedAccounts(
        inappAccounts: const [],
        walletsById: const {},
        mwaAddress: 'M',
      );
      expect(resolvePersistedAccount(accounts: list, savedId: null)!.id,
          'mwa:M');
    });

    test('empty → null', () {
      expect(resolvePersistedAccount(accounts: const [], savedId: 'x'), isNull);
    });
  });

  group('allowedAccountTypesForCurve', () {
    test('ed25519 → solana only', () {
      expect(allowedAccountTypesForCurve('ed25519'), ['solana']);
    });
    test('secp256k1 → ethereum + bitcoin', () {
      expect(allowedAccountTypesForCurve('secp256k1'), ['ethereum', 'bitcoin']);
    });
    test('unknown / null → empty', () {
      expect(allowedAccountTypesForCurve('bogus'), isEmpty);
      expect(allowedAccountTypesForCurve(null), isEmpty);
    });
  });

  group('addAccountTarget', () {
    final inappSol = buildUnifiedAccounts(
      inappAccounts: [_acct(id: 'a1', wallet: 'w1')],
      walletsById: {'w1': _wallet(id: 'w1')},
    ).single;
    final mwa = buildUnifiedAccounts(
      inappAccounts: const [],
      walletsById: const {},
      mwaAddress: 'M',
    ).single;

    test('current is in-app → returns current', () {
      expect(addAccountTarget([inappSol, mwa], inappSol), inappSol);
    });
    test('current is MWA → falls back to first in-app', () {
      expect(addAccountTarget([inappSol, mwa], mwa), inappSol);
    });
    test('no in-app account → null (MWA cannot add accounts)', () {
      expect(addAccountTarget([mwa], mwa), isNull);
    });
  });

  group('suggestAccountName / chainLabel', () {
    test('suggestAccountName is 1-based on existing count', () {
      expect(suggestAccountName(0), 'Account 1');
      expect(suggestAccountName(3), 'Account 4');
    });
    test('chainLabel maps known chains, title-cases the rest', () {
      expect(chainLabel('solana'), 'Solana');
      expect(chainLabel('ethereum'), 'Ethereum');
      expect(chainLabel('bitcoin'), 'Bitcoin');
      expect(chainLabel('polygon'), 'Polygon');
      expect(chainLabel(''), '');
    });
  });

  group('solanaOnlyFeaturesEnabled (chain gating)', () {
    final solana = buildUnifiedAccounts(
      inappAccounts: [_acct(id: 'a1', wallet: 'w1', type: 'solana')],
      walletsById: {'w1': _wallet(id: 'w1')},
    ).single;
    final eth = buildUnifiedAccounts(
      inappAccounts: [_acct(id: 'a2', wallet: 'w2', type: 'ethereum')],
      walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
    ).single;
    final mwa = buildUnifiedAccounts(
      inappAccounts: const [],
      walletsById: const {},
      mwaAddress: 'M',
    ).single;

    test('enabled for a Solana account', () {
      expect(solanaOnlyFeaturesEnabled(solana), isTrue);
    });
    test('enabled for the MWA account (Seed Vault is Solana)', () {
      expect(solanaOnlyFeaturesEnabled(mwa), isTrue);
    });
    test('enabled when no account yet (Solana-first default)', () {
      expect(solanaOnlyFeaturesEnabled(null), isTrue);
    });
    test('disabled for a known non-Solana (EVM) account', () {
      expect(solanaOnlyFeaturesEnabled(eth), isFalse);
    });
  });
}
