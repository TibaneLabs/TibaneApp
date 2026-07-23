import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart'
    show Account, Network, NetworkType, Wallet;
import 'package:tibaneapp/services/wallet/unified_account.dart';

/// Unit tests for the account-centric model (Atonline-parity Phase 4b-1). The
/// builder + resolvers are pure top-level functions, so they're verified here
/// without a libwallet client; `WalletService.refreshAccounts/setCurrentAccount`
/// (which drive backend switching) are device-verified.

Account _acct({
  required String id,
  required String wallet,
  String name = 'Account 1',
  int index = 0,
  String type = 'solana',
  String? address,
}) => Account(
  id: id,
  wallet: wallet,
  name: name,
  index: index,
  type: type,
  path: '',
  // Default to a type-appropriate, usable address so accounts pass
  // [isUsableAccount] unless a test overrides it (e.g. with 'N/A' or a
  // mismatched format). Ethereum requires a 0x address.
  address: address ?? (type == 'ethereum' ? '0xAbc123' : 'addr'),
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

Network _network({
  required String id,
  required NetworkType type,
  required String chainId,
}) => Network(
  id: id,
  type: type,
  chainId: chainId,
  name: id,
  rpc: '',
  currencySymbol: '',
  currencyDecimals: 8,
  blockExplorer: '',
  testNet: false,
  priority: 0,
  created: DateTime(2020),
  updated: DateTime(2020),
);

void main() {
  group('buildUnifiedAccounts', () {
    test('in-app account: label "walletName - name", ids + chain mapped', () {
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
      expect(a.label, 'My Wallet - Main');
      expect(a.chain, 'solana');
      expect(a.isSolana, isTrue);
      expect(a.address, 'SoLaddr');
      expect(a.walletId, 'w1');
      expect(a.accountId, 'acc1');
      expect(a.curve, 'ed25519');
      expect(a.id, 'acc1');
    });

    test('missing wallet in map is treated as an orphan and hidden', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [_acct(id: 'acc1', wallet: 'w-missing', name: 'Main')],
        walletsById: const {},
      );
      expect(out, isEmpty);
    });

    test('default network account names display as account numbers', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [
          _acct(
            id: 'acc1',
            wallet: 'w1',
            name: 'Solana',
            index: 1,
            type: 'solana',
          ),
        ],
        walletsById: {'w1': _wallet(id: 'w1', name: 'My Wallet')},
      );
      expect(out.single.label, 'My Wallet - Account 2');
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
      expect(out.map((a) => a.id).toList(), [
        'a1',
        'a2',
        'bitcoin:a2',
        'bitcoin-cash:a2',
        'dogecoin:a2',
        'litecoin:a2',
        'mwa:M',
      ]);
      expect(out[1].chain, 'ethereum');
      expect(out[1].isSolana, isFalse);
      expect(out[1].curve, 'secp256k1');
      expect(out[2].chain, 'bitcoin');
      expect(out[2].isVirtual, isTrue);
      expect(out[2].accountId, 'a2');
      expect(out[3].chain, 'bitcoin-cash');
      expect(out[4].chain, 'dogecoin');
      expect(out[5].chain, 'litecoin');
      expect(out.last.backend, AccountBackend.mwa);
    });

    test(
      'main ethereum secp256k1 account surfaces Bitcoin-family contexts',
      () {
        final out = buildUnifiedAccounts(
          inappAccounts: [
            _acct(id: 'eth1', wallet: 'w2', name: 'Ethereum', type: 'ethereum'),
          ],
          walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
        );
        expect(out.map((a) => a.id).toList(), [
          'eth1',
          'bitcoin:eth1',
          'bitcoin-cash:eth1',
          'dogecoin:eth1',
          'litecoin:eth1',
        ]);
        final bitcoin = out.last;
        expect(bitcoin.backend, AccountBackend.inapp);
        expect(bitcoin.chain, 'litecoin');
        expect(bitcoin.address, '');
        expect(bitcoin.label, 'Wallet 1 - Account 1');
        expect(bitcoin.accountId, 'eth1');
        expect(bitcoin.isVirtual, isTrue);
      },
    );

    test('virtual Bitcoin context can use a pre-resolved Bitcoin address', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [
          _acct(id: 'eth1', wallet: 'w2', name: 'Main', type: 'ethereum'),
        ],
        walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
        bitcoinAddressesByAccountId: {
          'eth1': 'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh',
        },
      );
      final bitcoin = out.singleWhere((a) => a.chain == 'bitcoin');
      expect(bitcoin.address, 'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh');
    });

    test('manual preferred Ethereum account does not add Bitcoin contexts', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [
          _acct(
            id: 'eth1',
            wallet: 'w2',
            name: 'Trading',
            index: 1,
            type: 'ethereum',
          ),
        ],
        walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
        preferredChainsByAccountId: {'eth1': 'ethereum'},
      );
      expect(out.map((a) => a.id).toList(), ['eth1']);
      expect(out.single.chain, 'ethereum');
    });

    test('legacy manual preferred Bitcoin account is hidden', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [
          _acct(
            id: 'eth1',
            wallet: 'w2',
            name: 'Savings',
            index: 1,
            type: 'ethereum',
          ),
        ],
        walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
        bitcoinAddressesByAccountId: {
          'eth1': 'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh',
        },
        preferredChainsByAccountId: {'eth1': 'bitcoin'},
      );
      expect(out, isEmpty);
    });

    test('virtual Bitcoin context uses the active Bitcoin address', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [
          _acct(id: 'eth1', wallet: 'w2', name: 'Ethereum', type: 'ethereum'),
        ],
        walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
        currentAccountId: 'eth1',
        currentNetworkType: NetworkType.bitcoin,
        currentAddress: 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080',
      );
      final bitcoin = out.singleWhere((a) => a.chain == 'bitcoin');
      expect(bitcoin.address, 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080');
    });

    test('virtual Bitcoin context rejects an active 0x address', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [
          _acct(id: 'eth1', wallet: 'w2', name: 'Ethereum', type: 'ethereum'),
        ],
        walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
        currentAccountId: 'eth1',
        currentNetworkType: NetworkType.bitcoin,
        currentAddress: '0x4d9477b1cDf10155eE5E2c55F781D48B18fD59fE',
        bitcoinAddressesByAccountId: {
          'eth1': 'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh',
        },
      );
      final bitcoin = out.singleWhere((a) => a.chain == 'bitcoin');
      expect(bitcoin.address, 'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh');
    });

    test('avatar assets are mapped by displayed account id', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [
          _acct(id: 'sol1', wallet: 'w1', type: 'solana'),
          _acct(id: 'eth1', wallet: 'w2', type: 'ethereum'),
        ],
        walletsById: {
          'w1': _wallet(id: 'w1', curve: 'ed25519'),
          'w2': _wallet(id: 'w2', curve: 'secp256k1'),
        },
        accountAvatarAssetsById: const {
          'sol1': 'assets/account_pfps/account_pfp_01.png',
          'eth1': 'assets/account_pfps/account_pfp_02.png',
          'bitcoin:eth1': 'assets/account_pfps/account_pfp_03.png',
          'bitcoin-cash:eth1': 'assets/account_pfps/account_pfp_04.png',
          'dogecoin:eth1': 'assets/account_pfps/account_pfp_05.png',
          'litecoin:eth1': 'assets/account_pfps/account_pfp_06.png',
        },
      );
      expect(out.map((a) => a.avatarAsset).toList(), const [
        'assets/account_pfps/account_pfp_01.png',
        'assets/account_pfps/account_pfp_02.png',
        'assets/account_pfps/account_pfp_03.png',
        'assets/account_pfps/account_pfp_04.png',
        'assets/account_pfps/account_pfp_05.png',
        'assets/account_pfps/account_pfp_06.png',
      ]);
    });

    test('bitcoin account under secp256k1 wallet is hidden', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [
          _acct(
            id: 'btc1',
            wallet: 'w2',
            name: 'Bitcoin',
            type: 'bitcoin',
            address: 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080',
          ),
        ],
        walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
      );
      expect(out, isEmpty);
    });
  });

  group('Bitcoin address display helpers', () {
    test('accept native Bitcoin address shapes and reject EVM', () {
      expect(
        isBitcoinAddress('bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh'),
        isTrue,
      );
      expect(isBitcoinAddress('1BoatSLRHtKNngkdXEeobR76b53LETtpyT'), isTrue);
      expect(isBitcoinAddress('3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy'), isTrue);
      expect(
        isBitcoinAddress('0x4d9477b1cDf10155eE5E2c55F781D48B18fD59fE'),
        isFalse,
      );
    });

    test('pickBitcoinAddress skips 0x formats', () {
      expect(
        pickBitcoinAddress([
          '0x4d9477b1cDf10155eE5E2c55F781D48B18fD59fE',
          'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh',
        ]),
        'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh',
      );
      expect(
        pickBitcoinAddress(['0x4d9477b1cDf10155eE5E2c55F781D48B18fD59fE']),
        isNull,
      );
    });

    test('isBitcoinFamilyAddress accepts non-EVM Bitcoin-family addresses', () {
      expect(isBitcoinFamilyAddress('bitcoincash:qq07vng'), isTrue);
      expect(
        isBitcoinFamilyAddress('ltc1qxy2kgdygjrsqtzq2n0yrf2493p83kk'),
        isTrue,
      );
      expect(
        isBitcoinFamilyAddress('D8f1111111111111111111111111111111'),
        isTrue,
      );
      expect(
        isBitcoinFamilyAddress('0x4d9477b1cDf10155eE5E2c55F781D48B18fD59fE'),
        isFalse,
      );
    });
  });

  group('isUsableAccountAddress / N/A filtering', () {
    test('rejects empty, whitespace, and the "N/A" sentinel', () {
      expect(isUsableAccountAddress(null), isFalse);
      expect(isUsableAccountAddress(''), isFalse);
      expect(isUsableAccountAddress('   '), isFalse);
      expect(isUsableAccountAddress('N/A'), isFalse);
      expect(isUsableAccountAddress('  N/A  '), isFalse);
    });
    test('accepts a real address', () {
      expect(isUsableAccountAddress('SoLaddr'), isTrue);
      expect(isUsableAccountAddress('0xabc'), isTrue);
    });
    test('buildUnifiedAccounts drops "N/A"- and empty-address accounts', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [
          _acct(id: 'good', wallet: 'w1', name: 'Good', address: 'SoLaddr'),
          _acct(id: 'bad', wallet: 'w1', name: 'Bad', address: 'N/A'),
          _acct(id: 'empty', wallet: 'w1', name: 'Empty', address: ''),
        ],
        walletsById: {'w1': _wallet(id: 'w1')},
      );
      expect(out.map((a) => a.id).toList(), ['good']);
    });
    test('MWA account is unaffected by the in-app filter', () {
      final out = buildUnifiedAccounts(
        inappAccounts: [_acct(id: 'bad', wallet: 'w1', address: 'N/A')],
        walletsById: {'w1': _wallet(id: 'w1')},
        mwaAddress: 'MwaPubkey',
      );
      expect(out.map((a) => a.id).toList(), ['mwa:MwaPubkey']);
    });
  });

  group('isUsableAccount (single phantom filter)', () {
    test('rejects "N/A" / empty address', () {
      expect(
        isUsableAccount(
          _acct(id: 'a', wallet: 'w', address: 'N/A'),
          _wallet(id: 'w'),
        ),
        isFalse,
      );
      expect(
        isUsableAccount(
          _acct(id: 'a', wallet: 'w', address: ''),
          _wallet(id: 'w'),
        ),
        isFalse,
      );
    });
    test('rejects an ethereum account with a non-0x (base58) address', () {
      // The real bug: list() returns a phantom EVM account with the wallet's
      // base58 Solana address as a fallback.
      expect(
        isUsableAccount(
          _acct(
            id: 'a',
            wallet: 'w',
            type: 'ethereum',
            address: 'E47NsfqHUqGTVGGcUjBR1aTENJPxAbywEigVMKNtvNry',
          ),
          _wallet(id: 'w', curve: 'secp256k1'),
        ),
        isFalse,
      );
    });
    test('accepts an ethereum account with a 0x address', () {
      expect(
        isUsableAccount(
          _acct(
            id: 'a',
            wallet: 'w',
            type: 'ethereum',
            address: '0x4d9477b1cDf10155eE5E2c55F781D48B18fD59fE',
          ),
          _wallet(id: 'w', curve: 'secp256k1'),
        ),
        isTrue,
      );
    });
    test(
      'rejects type incompatible with wallet curve (ethereum under ed25519)',
      () {
        expect(
          isUsableAccount(
            _acct(id: 'a', wallet: 'w', type: 'ethereum', address: '0xabc'),
            _wallet(id: 'w', curve: 'ed25519'),
          ),
          isFalse,
        );
      },
    );
    test('accepts solana under ed25519', () {
      expect(
        isUsableAccount(
          _acct(id: 'a', wallet: 'w', type: 'solana', address: 'SoLaddr'),
          _wallet(id: 'w', curve: 'ed25519'),
        ),
        isTrue,
      );
    });
    test('unknown wallet (null) is rejected as an orphan account', () {
      expect(
        isUsableAccount(
          _acct(id: 'a', wallet: 'w', type: 'solana', address: 'SoL'),
          null,
        ),
        isFalse,
      );
      expect(
        isUsableAccount(
          _acct(id: 'a', wallet: 'w', type: 'ethereum', address: 'SoL'),
          null,
        ),
        isFalse,
      );
    });
    test(
      'buildUnifiedAccounts drops phantom ethereum accounts under ed25519',
      () {
        final out = buildUnifiedAccounts(
          inappAccounts: [
            _acct(id: 'sol', wallet: 'w1', type: 'solana', address: 'E47Nsf'),
            // Phantom: ethereum-typed under an ed25519 wallet, base58 fallback.
            _acct(
              id: 'phantom',
              wallet: 'w1',
              type: 'ethereum',
              address: 'E47Nsf',
            ),
          ],
          walletsById: {'w1': _wallet(id: 'w1', curve: 'ed25519')},
        );
        expect(out.map((a) => a.id).toList(), ['sol']);
      },
    );
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
      expect(
        resolvePersistedAccount(accounts: list, savedId: 'mwa:M')!.id,
        'mwa:M',
      );
    });

    test(
      'saved MWA gone (Seed Vault disconnected) → first in-app fallback',
      () {
        // Saved was the MWA account, but this launch only has in-app accounts.
        final list = buildUnifiedAccounts(
          inappAccounts: [inapp1],
          walletsById: wallets,
        );
        final r = resolvePersistedAccount(accounts: list, savedId: 'mwa:M');
        expect(r!.id, 'a1');
        expect(r.isInApp, isTrue);
      },
    );

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
      expect(
        resolvePersistedAccount(accounts: list, savedId: null)!.id,
        'mwa:M',
      );
    });

    test('empty → null', () {
      expect(resolvePersistedAccount(accounts: const [], savedId: 'x'), isNull);
    });
  });

  group('resolveCurrentAccount (account-centric startup)', () {
    // in-app account a1 (wallet w1) + a connected MWA account.
    final list = buildUnifiedAccounts(
      inappAccounts: [_acct(id: 'a1', wallet: 'w1', name: 'A1')],
      walletsById: {'w1': _wallet(id: 'w1')},
      mwaAddress: 'M',
    );

    test(
      'saved in-app id wins even when preferMwa (stale Seed Vault pubkey)',
      () {
        // The bug: a restored MWA pubkey set preferMwa=true and stole the current
        // account. The saved id must win.
        final r = resolveCurrentAccount(
          accounts: list,
          savedId: 'a1',
          preferMwa: true,
          activeInAppAccountId: null,
        );
        expect(r!.id, 'a1');
        expect(r.isInApp, isTrue);
      },
    );

    test('saved MWA id wins even when not preferMwa', () {
      final r = resolveCurrentAccount(
        accounts: list,
        savedId: 'mwa:M',
        preferMwa: false,
        activeInAppAccountId: 'a1',
      );
      expect(r!.id, 'mwa:M');
      expect(r.isMwa, isTrue);
    });

    test('no saved id + preferMwa → the MWA account', () {
      final r = resolveCurrentAccount(
        accounts: list,
        savedId: null,
        preferMwa: true,
        activeInAppAccountId: null,
      );
      expect(r!.isMwa, isTrue);
    });

    test('no saved id + !preferMwa → the live active in-app account', () {
      final r = resolveCurrentAccount(
        accounts: list,
        savedId: null,
        preferMwa: false,
        activeInAppAccountId: 'a1',
      );
      expect(r!.id, 'a1');
    });

    test('saved id gone (account removed) → falls back to first in-app', () {
      final r = resolveCurrentAccount(
        accounts: list,
        savedId: 'acct-deleted',
        preferMwa: false,
        activeInAppAccountId: null,
      );
      expect(r!.id, 'a1'); // first in-app fallback
    });

    test('live Bitcoin network resolves the virtual Bitcoin context', () {
      final bitcoinList = buildUnifiedAccounts(
        inappAccounts: [
          _acct(id: 'eth1', wallet: 'w2', name: 'Ethereum', type: 'ethereum'),
        ],
        walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
      );
      final r = resolveCurrentAccount(
        accounts: bitcoinList,
        savedId: null,
        preferMwa: false,
        activeInAppAccountId: 'eth1',
        activeNetworkType: NetworkType.bitcoin,
      );
      expect(r!.id, 'bitcoin:eth1');
      expect(r.chain, 'bitcoin');
      expect(r.isVirtual, isTrue);
    });

    test('live Dogecoin network resolves the Dogecoin context', () {
      final bitcoinList = buildUnifiedAccounts(
        inappAccounts: [
          _acct(id: 'eth1', wallet: 'w2', name: 'Ethereum', type: 'ethereum'),
        ],
        walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
      );
      final r = resolveCurrentAccount(
        accounts: bitcoinList,
        savedId: null,
        preferMwa: false,
        activeInAppAccountId: 'eth1',
        activeNetworkType: NetworkType.bitcoin,
        activeNetworkChainId: 'dogecoin',
      );
      expect(r!.id, 'dogecoin:eth1');
      expect(r.chain, 'dogecoin');
      expect(r.isVirtual, isTrue);
    });
  });

  group('allowedAccountTypesForCurve', () {
    test('ed25519 → solana only', () {
      expect(allowedAccountTypesForCurve('ed25519'), ['solana']);
    });
    test('secp256k1 → ethereum only', () {
      expect(allowedAccountTypesForCurve('secp256k1'), ['ethereum']);
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

  group('accountForWallet / firstInAppAccount (lockless switch targets)', () {
    final w1a = buildUnifiedAccounts(
      inappAccounts: [_acct(id: 'a1', wallet: 'w1', name: 'A1')],
      walletsById: {'w1': _wallet(id: 'w1')},
    ).single;
    final w2a = buildUnifiedAccounts(
      inappAccounts: [_acct(id: 'b1', wallet: 'w2', name: 'B1')],
      walletsById: {'w2': _wallet(id: 'w2')},
    ).single;
    final mwa = buildUnifiedAccounts(
      inappAccounts: const [],
      walletsById: const {},
      mwaAddress: 'M',
    ).single;

    test('accountForWallet returns the in-app account on that wallet', () {
      expect(accountForWallet([w1a, w2a, mwa], 'w2'), w2a);
    });
    test('accountForWallet returns null for an unknown wallet', () {
      expect(accountForWallet([w1a, mwa], 'w-missing'), isNull);
    });
    test('accountForWallet never returns the MWA account', () {
      // MWA has no walletId, so it can never match a wallet-id query.
      expect(accountForWallet([mwa], 'anything'), isNull);
    });
    test('firstInAppAccount returns the first in-app account', () {
      expect(firstInAppAccount([mwa, w1a, w2a]), w1a);
    });
    test('firstInAppAccount is null when only MWA is present', () {
      expect(firstInAppAccount([mwa]), isNull);
      expect(firstInAppAccount(const []), isNull);
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
      expect(chainLabel('bitcoin-cash'), 'Bitcoin Cash');
      expect(chainLabel('dogecoin'), 'Dogecoin');
      expect(chainLabel('litecoin'), 'Litecoin');
      expect(chainLabel('polygon'), 'Polygon');
      expect(chainLabel(''), '');
    });
    test('chainTicker maps known chains', () {
      expect(chainTicker('solana'), 'SOL');
      expect(chainTicker('ethereum'), 'ETH');
      expect(chainTicker('bitcoin'), 'BTC');
      expect(chainTicker('bitcoin-cash'), 'BCH');
      expect(chainTicker('dogecoin'), 'DOGE');
      expect(chainTicker('litecoin'), 'LTC');
    });
  });

  group('network compatibility (cross-chain account switch)', () {
    test('networkTypeForChain maps chains to network families', () {
      expect(networkTypeForChain('solana'), NetworkType.solana);
      expect(networkTypeForChain('ethereum'), NetworkType.evm);
      expect(networkTypeForChain('bitcoin'), NetworkType.bitcoin);
      expect(networkTypeForChain('bitcoin-cash'), NetworkType.bitcoin);
      expect(networkTypeForChain('dogecoin'), NetworkType.bitcoin);
      expect(networkTypeForChain('litecoin'), NetworkType.bitcoin);
      expect(networkTypeForChain('bogus'), NetworkType.solana); // Solana-first
    });
    test('accountMatchesNetwork', () {
      final sol = buildUnifiedAccounts(
        inappAccounts: [_acct(id: 'a', wallet: 'w', type: 'solana')],
        walletsById: {'w': _wallet(id: 'w')},
      ).single;
      final eth = buildUnifiedAccounts(
        inappAccounts: [_acct(id: 'b', wallet: 'w2', type: 'ethereum')],
        walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
      ).firstWhere((a) => a.chain == 'ethereum');
      final btc = buildUnifiedAccounts(
        inappAccounts: [_acct(id: 'b', wallet: 'w2', type: 'ethereum')],
        walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
      ).firstWhere((a) => a.chain == 'bitcoin');
      expect(accountMatchesNetwork(sol, NetworkType.solana), isTrue);
      expect(accountMatchesNetwork(sol, NetworkType.evm), isFalse);
      expect(accountMatchesNetwork(eth, NetworkType.evm), isTrue);
      expect(accountMatchesNetwork(eth, NetworkType.solana), isFalse);
      expect(accountMatchesNetwork(btc, NetworkType.bitcoin), isTrue);
      expect(
        accountMatchesNetwork(
          btc,
          NetworkType.bitcoin,
          networkChainId: 'bitcoin',
        ),
        isTrue,
      );
      expect(
        accountMatchesNetwork(
          btc,
          NetworkType.bitcoin,
          networkChainId: 'dogecoin',
        ),
        isFalse,
      );
      expect(accountMatchesNetwork(btc, NetworkType.evm), isFalse);
    });
    test('networksForAccount resolves a bitcoin account to its own coin only', () {
      final btc = buildUnifiedAccounts(
        inappAccounts: [_acct(id: 'b', wallet: 'w2', type: 'ethereum')],
        walletsById: {'w2': _wallet(id: 'w2', curve: 'secp256k1')},
      ).firstWhere((a) => a.chain == 'bitcoin');
      final networks = [
        _network(id: 'btc-net', type: NetworkType.bitcoin, chainId: 'bitcoin'),
        _network(id: 'ltc-net', type: NetworkType.bitcoin, chainId: 'litecoin'),
        _network(id: 'doge-net', type: NetworkType.bitcoin, chainId: 'dogecoin'),
      ];
      // Not just any NetworkType.bitcoin network — only the account's own coin
      // (guards the F6 regression where a BTC→LTC switch was a no-op).
      expect(networksForAccount(btc, networks).map((n) => n.id), ['btc-net']);
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
    ).firstWhere((a) => a.chain == 'ethereum');
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
