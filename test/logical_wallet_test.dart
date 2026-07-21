import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show Wallet;
import 'package:tibaneapp/services/wallet/logical_wallet.dart';

Wallet _wallet({
  required String id,
  required String name,
  required String curve,
  DateTime? created,
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
  keys: const [],
);

void main() {
  test('groups ed25519 and secp256k1 peers into one user-facing wallet', () {
    final groups = buildLogicalWallets([
      _wallet(id: 'sol', name: 'Main', curve: 'ed25519'),
      _wallet(
        id: 'eth',
        name: 'Main',
        curve: 'secp256k1',
        created: DateTime.utc(2026, 1, 1, 0, 4),
      ),
    ]);

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
}
