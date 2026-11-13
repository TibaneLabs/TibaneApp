import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show Account, Wallet;
import 'package:tibaneapp/services/wallet/hardware_wallet.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';

Wallet _wallet(String id, {String protocol = '', String curve = ''}) => Wallet(
  id: id,
  name: 'W-$id',
  curve: curve,
  protocol: protocol,
  threshold: 1,
  gen: 0,
  pubkey: '',
  chaincode: '',
  created: DateTime(2026),
  modified: DateTime(2026),
  keys: const [],
);

Account _account(
  String id,
  String wallet,
  String type,
  String address, {
  int index = 0,
}) => Account(
  id: id,
  wallet: wallet,
  name: '',
  index: index,
  type: type,
  path: '',
  address: address,
  uri: '',
  pubkey: '',
  chaincode: '',
  created: DateTime(2026),
  updated: DateTime(2026),
);

void main() {
  group('hardwareKindOfProtocol', () {
    test('maps libwallet signer protocols', () {
      expect(hardwareKindOfProtocol('catcard'), HardwareKind.catcard);
      expect(hardwareKindOfProtocol('ledger'), HardwareKind.ledger);
      expect(hardwareKindOfProtocol('airgap'), HardwareKind.airgap);
      expect(hardwareKindOfProtocol('mnemonic'), isNull);
      expect(hardwareKindOfProtocol(''), isNull);
      expect(hardwareKindOfProtocol(null), isNull);
    });

    test('only CatCard and Ledger can show an address', () {
      expect(hardwareCanShowAddress(HardwareKind.catcard), isTrue);
      expect(hardwareCanShowAddress(HardwareKind.ledger), isTrue);
      expect(hardwareCanShowAddress(HardwareKind.airgap), isFalse);
    });
  });

  group('isUsableAccount on a hardware wallet', () {
    // Hardware wallets mix curves: libwallet reports Curve "".
    final ledger = _wallet('l', protocol: 'ledger');

    test('keeps Solana, Ethereum and Bitcoin despite the empty curve', () {
      expect(
        isUsableAccount(_account('a', 'l', 'solana', 'So1'), ledger),
        isTrue,
      );
      expect(
        isUsableAccount(_account('b', 'l', 'ethereum', '0xabc'), ledger),
        isTrue,
      );
      expect(
        isUsableAccount(_account('c', 'l', 'bitcoin', 'bc1q'), ledger),
        isTrue,
      );
    });

    test('hides Tron (no screens for it) and broken addresses', () {
      expect(
        isUsableAccount(_account('d', 'l', 'tron', 'T9yD'), ledger),
        isFalse,
      );
      expect(
        isUsableAccount(_account('e', 'l', 'ethereum', 'N/A'), ledger),
        isFalse,
      );
      expect(
        isUsableAccount(_account('f', 'l', 'ethereum', 'So1'), ledger),
        isFalse,
      );
    });

    test('a software wallet with an empty curve is still rejected', () {
      expect(
        isUsableAccount(_account('g', 's', 'solana', 'So1'), _wallet('s')),
        isFalse,
      );
    });
  });

  group('buildUnifiedAccounts with a hardware wallet', () {
    final catcard = _wallet('cc', protocol: 'catcard');
    final accounts = [
      _account('sol', 'cc', 'solana', 'SoLaddr'),
      _account('eth', 'cc', 'ethereum', '0xethaddr'),
      _account('btc', 'cc', 'bitcoin', 'listed-btc'),
    ];

    test('lists every chain as its own account, tagged with the device', () {
      final out = buildUnifiedAccounts(
        inappAccounts: accounts,
        walletsById: {'cc': catcard},
        bitcoinAddressesByAccountId: const {'btc': 'bc1qmainnet'},
      );
      expect(out.map((a) => a.chain), ['solana', 'ethereum', 'bitcoin']);
      expect(out.every((a) => a.isInApp && a.isHardware), isTrue);
      expect(out.every((a) => a.hardware == HardwareKind.catcard), isTrue);
      expect(out.every((a) => a.isExternal), isTrue);
      // The Bitcoin account is Bitcoin only, at its mainnet address.
      final btc = out.firstWhere((a) => a.chain == 'bitcoin');
      expect(btc.address, 'bc1qmainnet');
      expect(btc.networkChainId, 'bitcoin');
      expect(btc.idOverride, isNull);
      // No BCH / DOGE / LTC contexts fan out of a device's keys.
      expect(out.any((a) => a.chain == 'dogecoin'), isFalse);
    });

    test('add-account never targets a hardware wallet', () {
      final hw = buildUnifiedAccounts(
        inappAccounts: accounts,
        walletsById: {'cc': catcard},
      );
      expect(addAccountTarget(hw, hw.first), isNull);
      final software = UnifiedAccount(
        backend: AccountBackend.inapp,
        chain: 'solana',
        address: 'x',
        label: 'x',
        walletId: 'sw',
        accountId: 'sw-sol',
      );
      expect(addAccountTarget([...hw, software], hw.first), software);
    });
  });
}
