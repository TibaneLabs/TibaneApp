import 'package:libwallet/libwallet.dart' show NetworkType;

import '../../constants/solana_constants.dart';
import '../../models/token_account.dart';
import '../rpc_service.dart';
import '../solana_common.dart';
import '../spl_instructions.dart';
import '../wallet_service.dart';

String? reclaimSolOwner(WalletService wallet) {
  final owner = wallet.publicKey;
  if (!wallet.isConnected || owner == null || owner.isEmpty) return null;
  if (wallet.kind == WalletKind.inapp) {
    final network = wallet.libwallet.currentNetwork;
    if (network == null ||
        network.type != NetworkType.solana ||
        network.testNet ||
        !const {'mainnet', 'mainnet-beta'}.contains(network.chainId) ||
        wallet.libwallet.accountId == null) {
      return null;
    }
  } else if (wallet.currentAccount?.isSolana != true) {
    return null;
  }
  return owner;
}

Future<List<TokenAccount>> scanReclaimableTokenAccounts(
  RpcService rpc,
  String owner,
) async {
  final programs = await Future.wait([
    rpc.getTokenAccountsByOwner(owner),
    rpc.getTokenAccountsByOwner(owner, token2022: true),
  ]).timeout(const Duration(seconds: 15));
  return [
    for (final account in programs.expand((accounts) => accounts))
      if (canReclaimTokenAccount(account, owner)) account,
  ];
}

BigInt reclaimableLamports(Iterable<TokenAccount> accounts) =>
    accounts.fold(BigInt.zero, (sum, account) => sum + account.rentLamports);

bool isReclaimDust(TokenAccount account) =>
    account.decimals == 6 && account.amount == BigInt.one;

bool canReclaimTokenAccount(TokenAccount account, String owner) =>
    account.owner == owner &&
    (account.closeAuthority == null || account.closeAuthority == owner) &&
    account.pubkey != owner &&
    (account.isEmpty || isReclaimDust(account)) &&
    !account.isNative &&
    account.mint != wsolMint &&
    account.rentLamports > BigInt.zero;

/// Burn and close must stay in the same transaction so a failed close
/// (for example, after a new deposit) also rolls back the burn.
List<SolanaInstruction> buildReclaimSolInstructions(
  Iterable<TokenAccount> accounts,
  String owner,
) {
  final seen = <String>{};
  return [
    for (final account in accounts)
      if (!canReclaimTokenAccount(account, owner) || !seen.add(account.pubkey))
        throw ArgumentError('Ineligible token account')
      else
        ...buildBurnAndCloseInstructions(
          tokenAccount: account.pubkey,
          mint: account.mint,
          owner: owner,
          amount: account.amount,
          decimals: account.decimals,
          isToken2022: account.isToken2022,
        ),
  ];
}
