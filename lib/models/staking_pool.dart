import 'dart:math';
import 'dart:typed_data';

import '../constants/solana_constants.dart';
import '../services/solana_common.dart';

class StakingPool {
  final String address;
  final String mint;
  final String tokenVault;
  final String authority;
  final BigInt totalStaked;
  final BigInt sumStakeExp;
  final BigInt tauSeconds;
  final BigInt baseTime;
  final BigInt accRewardPerWeightedShare;
  final BigInt lastUpdateTime;
  final int bump;
  final BigInt lastSyncedLamports;
  final BigInt minStakeAmount;
  final BigInt lockDurationSeconds;
  final BigInt unstakeCooldownSeconds;
  final BigInt initialBaseTime;

  // Metadata (fetched separately)
  String? tokenName;
  String? tokenSymbol;
  String? tokenImage;
  int tokenDecimals;
  int memberCount;
  BigInt rewardBalance;
  double? tokenPrice;
  BigInt tokenSupply;

  StakingPool({
    required this.address,
    required this.mint,
    required this.tokenVault,
    required this.authority,
    required this.totalStaked,
    required this.sumStakeExp,
    required this.tauSeconds,
    required this.baseTime,
    required this.accRewardPerWeightedShare,
    required this.lastUpdateTime,
    required this.bump,
    required this.lastSyncedLamports,
    required this.minStakeAmount,
    required this.lockDurationSeconds,
    required this.unstakeCooldownSeconds,
    required this.initialBaseTime,
    this.tokenName,
    this.tokenSymbol,
    this.tokenImage,
    this.tokenDecimals = 6,
    this.memberCount = 0,
    BigInt? rewardBalance,
    this.tokenPrice,
    BigInt? tokenSupply,
  }) : rewardBalance = rewardBalance ?? BigInt.zero,
       tokenSupply = tokenSupply ?? BigInt.zero;

  /// Market cap in USD, or null if price unavailable
  double? get marketCap {
    if (tokenPrice == null || tokenSupply == BigInt.zero) return null;
    final supplyDouble = tokenSupply.toDouble() / BigInt.from(10).pow(tokenDecimals).toDouble();
    return supplyDouble * tokenPrice!;
  }

  /// Pool age in seconds
  int get ageSeconds {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now - initialBaseTime.toInt();
  }

  /// Format tau as human-readable duration
  String get tauFormatted {
    final tau = tauSeconds.toInt();
    if (tau >= 86400) return '${tau ~/ 86400}d';
    if (tau >= 3600) return '${tau ~/ 3600}h';
    return '${tau ~/ 60}m';
  }

  /// Build a pool from a `Crypto/Solana/ChiefStaker` API row. The row
  /// contains rich metadata (name/symbol/logo/price/mcap/members) alongside
  /// the on-chain `Pool_Data` blob, so no follow-up RPC calls are required
  /// to render the list view.
  factory StakingPool.fromApi(Map<String, dynamic> row) {
    final poolData = (row['Pool_Data'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final solBalance = _asDouble(row['Sol_Balance']) ?? 0.0;
    return StakingPool(
      address: row['Pool_Address'] as String,
      mint: row['Mint'] as String,
      tokenVault: poolData['tokenVault'] as String? ?? '',
      authority: poolData['authority'] as String? ?? '',
      totalStaked: _asBigInt(poolData['totalStaked']),
      sumStakeExp: _asBigInt(poolData['sumStakeExp']),
      tauSeconds: _asBigInt(poolData['tauSeconds']),
      baseTime: _asBigInt(poolData['baseTime']),
      accRewardPerWeightedShare: _asBigInt(poolData['accRewardPerWeightedShare']),
      lastUpdateTime: _asBigInt(poolData['lastUpdateTime']),
      bump: _asInt(poolData['bump']),
      lastSyncedLamports: _asBigInt(poolData['lastSyncedLamports']),
      minStakeAmount: _asBigInt(poolData['minStakeAmount']),
      lockDurationSeconds: _asBigInt(poolData['lockDurationSeconds']),
      unstakeCooldownSeconds: _asBigInt(poolData['unstakeCooldownSeconds']),
      initialBaseTime: _asBigInt(poolData['initialBaseTime']),
      tokenName: row['Name'] as String?,
      tokenSymbol: row['Symbol'] as String?,
      tokenImage: row['Logo_Url'] as String?,
      tokenDecimals: _asInt(row['Decimals']),
      memberCount: _asInt(row['Members']),
      rewardBalance: BigInt.from((solBalance * 1e9).round()),
      tokenPrice: _asDouble(row['Price_Usd']),
      tokenSupply: _asBigInt(row['Supply']),
    );
  }

  static StakingPool? deserialize(String address, Uint8List data) {
    if (data.length < 264) return null;

    // Check discriminator
    for (int i = 0; i < 8; i++) {
      if (data[i] != poolDiscriminator[i]) return null;
    }

    final bd = ByteData.sublistView(data);
    int offset = 8;

    final mint = _readBase58(data, offset); offset += 32;
    final tokenVault = _readBase58(data, offset); offset += 32;
    offset += 32; // reward_vault (deprecated)
    final authority = _readBase58(data, offset); offset += 32;
    final totalStaked = _readU128(bd, offset); offset += 16;
    final sumStakeExp = _readU256(bd, offset); offset += 32;
    final tauSeconds = _readU64(bd, offset); offset += 8;
    final baseTime = _readI64(bd, offset); offset += 8;
    final accRewardPerWeightedShare = _readU128(bd, offset); offset += 16;
    final lastUpdateTime = _readI64(bd, offset); offset += 8;
    final bump = data[offset]; offset += 1;
    final lastSyncedLamports = _readU64(bd, offset); offset += 8;
    final minStakeAmount = _readU64(bd, offset); offset += 8;
    final lockDurationSeconds = _readU64(bd, offset); offset += 8;
    final unstakeCooldownSeconds = _readU64(bd, offset); offset += 8;
    final initialBaseTime = _readI64(bd, offset);

    return StakingPool(
      address: address,
      mint: mint,
      tokenVault: tokenVault,
      authority: authority,
      totalStaked: totalStaked,
      sumStakeExp: sumStakeExp,
      tauSeconds: tauSeconds,
      baseTime: baseTime,
      accRewardPerWeightedShare: accRewardPerWeightedShare,
      lastUpdateTime: lastUpdateTime,
      bump: bump,
      lastSyncedLamports: lastSyncedLamports,
      minStakeAmount: minStakeAmount,
      lockDurationSeconds: lockDurationSeconds,
      unstakeCooldownSeconds: unstakeCooldownSeconds,
      initialBaseTime: initialBaseTime,
    );
  }
}

class UserStake {
  final String owner;
  final String pool;
  final BigInt amount;
  final BigInt stakeTime;
  final BigInt expStartFactor;
  final BigInt rewardDebt;
  final int bump;
  final BigInt unstakeRequestAmount;
  final BigInt unstakeRequestTime;
  final BigInt lastStakeTime;
  final BigInt baseTimeSnapshot;
  final BigInt totalRewardsClaimed;
  final BigInt claimedRewardsWad;

  UserStake({
    required this.owner,
    required this.pool,
    required this.amount,
    required this.stakeTime,
    required this.expStartFactor,
    required this.rewardDebt,
    required this.bump,
    required this.unstakeRequestAmount,
    required this.unstakeRequestTime,
    required this.lastStakeTime,
    required this.baseTimeSnapshot,
    required this.totalRewardsClaimed,
    required this.claimedRewardsWad,
  });

  bool get hasUnstakeRequest => unstakeRequestAmount > BigInt.zero;

  static UserStake? deserialize(Uint8List data) {
    if (data.length < 153) return null;

    for (int i = 0; i < 8; i++) {
      if (data[i] != userStakeDiscriminator[i]) return null;
    }

    final bd = ByteData.sublistView(data);
    int offset = 8;

    final owner = _readBase58(data, offset); offset += 32;
    final pool = _readBase58(data, offset); offset += 32;
    final amount = _readU64(bd, offset); offset += 8;
    final stakeTime = _readI64(bd, offset); offset += 8;
    final expStartFactor = _readU128(bd, offset); offset += 16;
    final rewardDebt = _readU128(bd, offset); offset += 16;
    final bump = data[offset]; offset += 1;
    final unstakeRequestAmount = _readU64(bd, offset); offset += 8;
    final unstakeRequestTime = _readI64(bd, offset); offset += 8;
    final lastStakeTime = _readI64(bd, offset); offset += 8;
    final baseTimeSnapshot = _readI64(bd, offset); offset += 8;
    final totalRewardsClaimed = data.length >= offset + 8 ? _readU64(bd, offset) : BigInt.zero; offset += 8;
    final claimedRewardsWad = data.length >= offset + 16 ? _readU128(bd, offset) : BigInt.zero;

    return UserStake(
      owner: owner,
      pool: pool,
      amount: amount,
      stakeTime: stakeTime,
      expStartFactor: expStartFactor,
      rewardDebt: rewardDebt,
      bump: bump,
      unstakeRequestAmount: unstakeRequestAmount,
      unstakeRequestTime: unstakeRequestTime,
      lastStakeTime: lastStakeTime,
      baseTimeSnapshot: baseTimeSnapshot,
      totalRewardsClaimed: totalRewardsClaimed,
      claimedRewardsWad: claimedRewardsWad,
    );
  }
}

/// Estimate pending rewards for a user stake (in lamports)
BigInt estimatePendingRewards(StakingPool pool, UserStake stake) {
  if (stake.amount == BigInt.zero) return BigInt.zero;

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final age = now - pool.baseTime.toInt();
  final tau = pool.tauSeconds.toInt();
  final expNegCurrent = _expNegWad(age, tau);
  final decay = _wadMul(expNegCurrent, stake.expStartFactor);
  final weightFactor = wad - decay;
  final amountWad = stake.amount * wad;
  final userWeighted = _wadMul(amountWad, weightFactor);

  if (userWeighted == BigInt.zero) return BigInt.zero;

  final snapshot = _wadDiv(stake.rewardDebt, amountWad);
  final deltaRps = pool.accRewardPerWeightedShare - snapshot;
  if (deltaRps <= BigInt.zero) return BigInt.zero;

  final fullEntitlement = _wadMul(userWeighted, deltaRps);
  final pending = fullEntitlement > stake.claimedRewardsWad
      ? fullEntitlement - stake.claimedRewardsWad
      : BigInt.zero;
  final pendingLamports = pending ~/ wad;
  return pendingLamports > BigInt.zero ? pendingLamports : BigInt.zero;
}

/// Estimate SOL rewards a user can't claim yet due to immature weight
BigInt estimateImmatureRewards(StakingPool pool, UserStake stake) {
  if (stake.amount == BigInt.zero) return BigInt.zero;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final age = now - pool.baseTime.toInt();
  final tau = pool.tauSeconds.toInt();
  final expNegCurrent = _expNegWad(age, tau);
  final decay = _wadMul(expNegCurrent, stake.expStartFactor);
  if (decay == BigInt.zero) return BigInt.zero;

  final amountWad = stake.amount * wad;
  final userWeighted = _wadMul(amountWad, wad - decay);

  final snapshot = _wadDiv(stake.rewardDebt, amountWad);
  final deltaRps = pool.accRewardPerWeightedShare - snapshot;
  if (deltaRps <= BigInt.zero) return BigInt.zero;

  final maxPending = _wadMul(amountWad, deltaRps);
  final actualPending = _wadMul(userWeighted, deltaRps);

  final maxLamports = maxPending ~/ wad;
  final actualLamports = actualPending ~/ wad;
  final immature = maxLamports - actualLamports;
  return immature > BigInt.zero ? immature : BigInt.zero;
}

/// Calculate current weight percentage (0-100)
double calculateWeightPercent(BigInt tauSeconds, BigInt baseTime, BigInt expStartFactor) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final age = now - baseTime.toInt();
  if (age <= 0) return 0;
  final tau = tauSeconds.toInt();
  if (tau <= 0) return 100;
  final decay = exp(-age / tau);
  final weight = 1 - decay * expStartFactor.toDouble() / 1e18;
  return (weight * 100).clamp(0, 100);
}

// Binary helpers
BigInt _readU64(ByteData bd, int offset) {
  final lo = bd.getUint32(offset, Endian.little);
  final hi = bd.getUint32(offset + 4, Endian.little);
  return BigInt.from(lo) + (BigInt.from(hi) << 32);
}

BigInt _readI64(ByteData bd, int offset) {
  final lo = bd.getUint32(offset, Endian.little);
  final hi = bd.getInt32(offset + 4, Endian.little);
  return BigInt.from(lo) + (BigInt.from(hi) << 32);
}

BigInt _readU128(ByteData bd, int offset) {
  final lo = _readU64(bd, offset);
  final hi = _readU64(bd, offset + 8);
  return lo + (hi << 64);
}

BigInt _readU256(ByteData bd, int offset) {
  final a = _readU64(bd, offset);
  final b = _readU64(bd, offset + 8);
  final c = _readU64(bd, offset + 16);
  final d = _readU64(bd, offset + 24);
  return a | (b << 64) | (c << 128) | (d << 192);
}

String _readBase58(Uint8List data, int offset) {
  return base58Encode(data.sublist(offset, offset + 32));
}

BigInt _expNegWad(int age, int tau) {
  if (tau <= 0) return BigInt.zero;
  if (age <= 0) return wad;
  final val = exp(-age / tau);
  return BigInt.from((val * 1e18).round());
}

BigInt _wadMul(BigInt a, BigInt b) => (a * b) ~/ wad;
BigInt _wadDiv(BigInt a, BigInt b) => b == BigInt.zero ? BigInt.zero : (a * wad) ~/ b;

// API field coercion: the Tibane backend serializes numeric columns as
// strings; Pool_Data blobs may arrive as ints, strings, or bigint strings.
BigInt _asBigInt(dynamic v) {
  if (v == null) return BigInt.zero;
  if (v is BigInt) return v;
  if (v is int) return BigInt.from(v);
  if (v is num) return BigInt.from(v.toInt());
  if (v is String && v.isNotEmpty) {
    return BigInt.tryParse(v) ?? BigInt.zero;
  }
  return BigInt.zero;
}

int _asInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String && v.isNotEmpty) return int.tryParse(v) ?? 0;
  return 0;
}

double? _asDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String && v.isNotEmpty) return double.tryParse(v);
  return null;
}
