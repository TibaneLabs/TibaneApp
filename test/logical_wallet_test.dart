import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show Wallet, WalletKey;
import 'package:tibaneapp/services/wallet/logical_wallet.dart';

Wallet _wallet({
  required String id,
  required String name,
  required String curve,
  DateTime? created,
  List<WalletKey> keys = const [],
}) => Wallet(
  id: id,
  name: name,
  curve: curve,
  threshold: 1,
  gen: 0,
  pubkey: '',
  chaincode: '',
  created: created ?? DateTime.utc(2026, 1, 1),
  modified: created ?? DateTime.utc(2026, 1, 1),
  keys: keys,
);

void main() {
  test('unrelated same-name wallets stay separate without a relation', () {
    final groups = buildLogicalWallets([
      _wallet(id: 'independent-sol', name: 'Wallet', curve: 'ed25519'),
      _wallet(id: 'independent-evm', name: 'Wallet', curve: 'secp256k1'),
    ]);
    // There is no persisted parent/group relation in this input. This records
    // the heuristic grouping used by group-wide export/remove operations.
    expect(groups, hasLength(2));
    expect(groups.every((group) => group.wallets.length == 1), isTrue);
  });

  test('groups ed25519 and secp256k1 peers into one user-facing wallet', () {
    final groups = buildLogicalWallets([
      _wallet(id: 'sol', name: 'Main', curve: 'ed25519'),
      _wallet(
        id: 'eth',
        name: 'Main',
        curve: 'secp256k1',
        created: DateTime.utc(2026, 1, 1, 0, 4),
      ),
    ], walletGroups: const {'sol': 'main', 'eth': 'main'});

    expect(groups, hasLength(1));
    expect(groups.single.chains, [
      'solana',
      'ethereum',
      'bitcoin',
      'bitcoin-cash',
      'dogecoin',
      'litecoin',
    ]);
    expect(groups.single.walletForChain('solana')!.id, 'sol');
    expect(groups.single.walletForChain('ethereum')!.id, 'eth');
    expect(groups.single.walletForChain('bitcoin')!.id, 'eth');
    expect(groups.single.walletForChain('bitcoin-cash')!.id, 'eth');
    expect(groups.single.walletForChain('dogecoin')!.id, 'eth');
    expect(groups.single.walletForChain('litecoin')!.id, 'eth');
  });

  test('does not group wallets with different names', () {
    final groups = buildLogicalWallets([
      _wallet(id: 'one', name: 'One', curve: 'ed25519'),
      _wallet(id: 'two', name: 'Two', curve: 'secp256k1'),
    ]);

    expect(groups, hasLength(2));
  });

  test('attaches a technical child wallet to its selected logical wallet', () {
    final groups = buildLogicalWallets(
      [
        _wallet(id: 'sol', name: 'Main', curve: 'ed25519'),
        _wallet(id: 'eth', name: 'Main', curve: 'secp256k1'),
        _wallet(
          id: 'extra-sol',
          name: 'Main',
          curve: 'ed25519',
          created: DateTime.utc(2026, 1, 2),
        ),
      ],
      attachedWalletParents: const {'extra-sol': 'sol'},
      walletGroups: const {'sol': 'main', 'eth': 'main'},
    );

    expect(groups, hasLength(1));
    expect(groups.single.wallets.map((wallet) => wallet.id), [
      'sol',
      'extra-sol',
      'eth',
    ]);
    expect(groups.single.walletForChain('solana')!.id, 'sol');
  });

  test('classifies wallet contents without exposing key internals', () {
    final native = _wallet(id: 'native', name: 'Main', curve: 'ed25519');
    final added = _wallet(id: 'added', name: 'Main', curve: 'ed25519');
    final imported = _wallet(
      id: 'imported',
      name: 'Main',
      curve: 'ed25519',
      keys: const [
        WalletKey(
          id: 'key',
          wallet: 'imported',
          type: 'StoreKey',
          key: 'stored',
          gen: 1,
        ),
      ],
    );

    const attachments = {'added': 'native', 'imported': 'native'};
    expect(
      walletContentsKind(native, attachedWalletParents: attachments),
      WalletContentsKind.native,
    );
    expect(
      walletContentsKind(added, attachedWalletParents: attachments),
      WalletContentsKind.added,
    );
    expect(
      walletContentsKind(imported, attachedWalletParents: attachments),
      WalletContentsKind.imported,
    );
  });
}
