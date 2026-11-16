import 'dart:typed_data';

import '../models/staking_pool.dart';
import 'chiefstaker_api.dart';
import 'rpc_service.dart';
import 'solana_common.dart';
import 'staker_instructions.dart';

typedef StakingPosition = ({StakingPool pool, UserStake stake, BigInt rewards});

class StakingPositions {
  final RpcService _rpc;
  final ChiefStakerApi _api;

  StakingPositions(this._rpc, this._api);

  Future<List<StakingPosition>> load(
    String owner,
    List<StakingPool> directory,
  ) async {
    final known = {for (final pool in directory) pool.address: pool};
    final stakes = {
      for (final stake in await _rpc.getUserStakes(owner))
        if (stake.amount > BigInt.zero || stake.hasUnstakeRequest)
          stake.pool: stake,
    }.values.toList();

    final positions = <StakingPosition>[];
    for (var i = 0; i < stakes.length; i += 8) {
      positions.addAll(
        await Future.wait(
          stakes.skip(i).take(8).map((stake) async {
            final pool = await _rpc.getStakingPool(stake.pool);
            if (pool == null) throw StateError('Staking pool unavailable');
            final candidate =
                known[pool.address] ?? await _api.getByMint(pool.mint);
            final metadata =
                candidate?.mint == pool.mint &&
                    candidate?.address == pool.address
                ? candidate
                : null;
            pool.tokenName = metadata?.tokenName;
            pool.tokenSymbol = metadata?.tokenSymbol;
            pool.tokenImage = metadata?.tokenImage;
            pool.memberCount = metadata?.memberCount ?? pool.memberCount;
            pool.tokenPrice = metadata?.tokenPrice;
            if (metadata != null) pool.tokenSupply = metadata.tokenSupply;
            pool.tokenDecimals =
                metadata?.tokenDecimals ??
                await _rpc.getTokenDecimals(pool.mint);
            return (
              pool: pool,
              stake: stake,
              rewards: estimatePendingRewards(pool, stake),
            );
          }),
        ),
      );
    }
    return positions..sort((a, b) => b.rewards.compareTo(a.rewards));
  }
}

// A legacy transaction fits 14 claims: a shared fee payer, system and
// staking program plus two unique writable accounts per claim.
const maxClaimsPerTransaction = 14;

Uint8List buildStakingClaim({
  required String owner,
  required String blockhash,
  required Iterable<String> pools,
}) {
  final unique = pools.toSet();
  if (unique.isEmpty || unique.length > maxClaimsPerTransaction) {
    throw ArgumentError('Invalid claim count');
  }
  final transaction = buildTransaction(
    recentBlockhash: blockhash,
    feePayer: owner,
    instructions: [
      for (final pool in unique) createClaimRewardsIx(pool: pool, user: owner),
    ],
  );
  if (transaction.length > 1232) throw StateError('Claim exceeds packet size');
  return transaction;
}
