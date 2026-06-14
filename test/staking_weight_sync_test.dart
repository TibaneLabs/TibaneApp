import 'package:flutter_test/flutter_test.dart';

import 'package:tibaneapp/models/staking_pool.dart';

/// Build a pool with only the fields the weight math reads. Anything
/// irrelevant to `calculateWeightPercent` is given a benign zero.
StakingPool _pool({
  required BigInt baseTime,
  required BigInt initialBaseTime,
  required BigInt tauSeconds,
}) =>
    StakingPool(
      address: 'POOL',
      mint: '',
      tokenVault: '',
      authority: '',
      totalStaked: BigInt.zero,
      sumStakeExp: BigInt.zero,
      tauSeconds: tauSeconds,
      baseTime: baseTime,
      accRewardPerWeightedShare: BigInt.zero,
      lastUpdateTime: BigInt.zero,
      bump: 0,
      lastSyncedLamports: BigInt.zero,
      minStakeAmount: BigInt.zero,
      lockDurationSeconds: BigInt.zero,
      unstakeCooldownSeconds: BigInt.zero,
      initialBaseTime: initialBaseTime,
    );

UserStake _stake({
  required BigInt expStartFactor,
  required BigInt baseTimeSnapshot,
  BigInt? amount,
}) =>
    UserStake(
      owner: 'OWNER',
      pool: 'POOL',
      amount: amount ?? BigInt.from(1),
      stakeTime: BigInt.zero,
      expStartFactor: expStartFactor,
      rewardDebt: BigInt.zero,
      bump: 0,
      unstakeRequestAmount: BigInt.zero,
      unstakeRequestTime: BigInt.zero,
      lastStakeTime: BigInt.zero,
      baseTimeSnapshot: baseTimeSnapshot,
      totalRewardsClaimed: BigInt.zero,
      claimedRewardsWad: BigInt.zero,
    );

void main() {
  group('calculateWeightPercent rebase sync', () {
    // Mainnet pool FLNFLHnFp8S2ENwTDRatNnGH5TCvyUrp7wHh24BqJ1bJ
    // (mint DRtvTCz…pump). Live values captured while reproducing
    // the bug: user 2bJ…Ac8E had a baseTimeSnapshot at the pool's
    // initialBaseTime (i.e. never re-synced) and was displaying 0%,
    // while peer YeL…ig96 — who'd transacted post-rebase — showed
    // 98.1%. Both staked at the same time so the synced math must
    // converge them.
    final pool = _pool(
      baseTime: BigInt.from(1781399955),
      initialBaseTime: BigInt.from(1770685375),
      tauSeconds: BigInt.from(2592000),
    );

    test('un-synced user no longer clamps to 0% after rebase', () {
      final stake = _stake(
        expStartFactor: BigInt.parse('1139569234688720105'),
        baseTimeSnapshot: BigInt.from(1770685375),
      );
      final weight = calculateWeightPercent(pool, stake);
      // exp(-(1781399955-1770685375)/2592000) ≈ 0.01603, so the
      // synced factor is ≈ 0.01828 (down from the raw 1.140 that
      // produced decay > 1 → 0%). Display should land near 98%.
      expect(weight, greaterThan(95));
      expect(weight, lessThan(100));
    });

    test('legacy account (baseTimeSnapshot=0) syncs against initialBaseTime',
        () {
      // Pre-snapshot accounts get the same treatment, using
      // initialBaseTime as the implicit calibration anchor.
      final stake = _stake(
        expStartFactor: BigInt.parse('1139569234688720105'),
        baseTimeSnapshot: BigInt.zero,
      );
      final weight = calculateWeightPercent(pool, stake);
      expect(weight, greaterThan(95));
      expect(weight, lessThan(100));
    });

    test('already-synced user (baseTimeSnapshot == baseTime) is untouched',
        () {
      // Sanity: no sync needed when the snapshot matches the pool's
      // current base. The factor was calibrated post-rebase so the
      // value flows through unchanged — but the displayed weight is
      // still a function of age, which is ~0 here, so it should be
      // very close to (1 - factor/WAD) * 100.
      final pool0 = _pool(
        baseTime: BigInt.from(1781399955),
        initialBaseTime: BigInt.from(1770685375),
        tauSeconds: BigInt.from(2592000),
      );
      // A reasonable post-rebase factor: 0.018 WAD-scaled. With
      // age ≈ 0 → exp(-age/tau) ≈ 1 → decay ≈ 0.018 → weight ≈ 98%.
      final stake = _stake(
        expStartFactor: BigInt.parse('18000000000000000'),
        baseTimeSnapshot: BigInt.from(1781399955),
      );
      final weight = calculateWeightPercent(pool0, stake);
      expect(weight, greaterThan(95));
      expect(weight, lessThan(100));
    });
  });
}
