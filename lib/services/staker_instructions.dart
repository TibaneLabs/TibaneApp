/// ChiefStaker program instruction builders - port of tibanenet/src/lib/staker.ts
library;

import 'dart:typed_data';

import '../constants/solana_constants.dart';
import 'solana_common.dart';
import 'spl_instructions.dart';

// ─── PDA derivation ──────────────────────────────────────────────────────────

String derivePoolPDA(String mint) {
  final (addr, _) = findProgramAddressFromStrings([
    Uint8List.fromList(poolSeed),
    base58Decode(mint),
  ], chiefStakerProgramId);
  return addr;
}

String deriveTokenVaultPDA(String pool) {
  final (addr, _) = findProgramAddressFromStrings([
    Uint8List.fromList(tokenVaultSeed),
    base58Decode(pool),
  ], chiefStakerProgramId);
  return addr;
}

String deriveUserStakePDA(String pool, String user) {
  final (addr, _) = findProgramAddressFromStrings([
    Uint8List.fromList(stakeSeed),
    base58Decode(pool),
    base58Decode(user),
  ], chiefStakerProgramId);
  return addr;
}

String derivePoolMetadataPDA(String pool) {
  final (addr, _) = findProgramAddressFromStrings([
    Uint8List.fromList(metadataSeed),
    base58Decode(pool),
  ], chiefStakerProgramId);
  return addr;
}

// ─── Instruction builders ────────────────────────────────────────────────────

SolanaInstruction createStakeIx({
  required String pool,
  required String mint,
  required String user,
  required BigInt amount,
  required String tokenProgramId,
}) {
  final userStake = deriveUserStakePDA(pool, user);
  final tokenVault = deriveTokenVaultPDA(pool);
  final userToken = deriveATA(user, mint, tokenProgramId);
  final metadata = derivePoolMetadataPDA(pool);

  final data = ByteData(1 + 8);
  data.setUint8(0, StakerInstruction.stake);
  data.setUint64(1, amount.toInt(), Endian.little);

  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [
      AccountMeta.fromBase58(pool, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(userStake, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(tokenVault, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(userToken, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(mint, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(user, isSigner: true, isWritable: true),
      AccountMeta.fromBase58(
        systemProgramId,
        isSigner: false,
        isWritable: false,
      ),
      AccountMeta.fromBase58(
        tokenProgramId,
        isSigner: false,
        isWritable: false,
      ),
      // Metadata PDA: required since chiefstaker 91ce912 — keeps
      // member_count exact (+1 on a new stake). Uninitialized for
      // metadata-less pools, which the program tolerates.
      AccountMeta.fromBase58(metadata, isSigner: false, isWritable: true),
    ],
    data: Uint8List.view(data.buffer),
  );
}

SolanaInstruction createStakeOnBehalfIx({
  required String pool,
  required String mint,
  required String staker,
  required String beneficiary,
  required BigInt amount,
  required String tokenProgramId,
}) {
  final beneficiaryStake = deriveUserStakePDA(pool, beneficiary);
  final tokenVault = deriveTokenVaultPDA(pool);
  final stakerToken = deriveATA(staker, mint, tokenProgramId);
  final metadata = derivePoolMetadataPDA(pool);

  final data = ByteData(1 + 8);
  data.setUint8(0, StakerInstruction.stakeOnBehalf);
  data.setUint64(1, amount.toInt(), Endian.little);

  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [
      AccountMeta.fromBase58(pool, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(
        beneficiaryStake,
        isSigner: false,
        isWritable: true,
      ),
      AccountMeta.fromBase58(tokenVault, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(stakerToken, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(mint, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(staker, isSigner: true, isWritable: true),
      AccountMeta.fromBase58(beneficiary, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(
        systemProgramId,
        isSigner: false,
        isWritable: false,
      ),
      AccountMeta.fromBase58(
        tokenProgramId,
        isSigner: false,
        isWritable: false,
      ),
      // Metadata PDA: required since chiefstaker 91ce912 (+1 on a new stake).
      AccountMeta.fromBase58(metadata, isSigner: false, isWritable: true),
    ],
    data: Uint8List.view(data.buffer),
  );
}

SolanaInstruction createRequestUnstakeIx({
  required String pool,
  required String user,
  required BigInt amount,
}) {
  final userStake = deriveUserStakePDA(pool, user);

  final data = ByteData(1 + 8);
  data.setUint8(0, StakerInstruction.requestUnstake);
  data.setUint64(1, amount.toInt(), Endian.little);

  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [
      AccountMeta.fromBase58(pool, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(userStake, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(user, isSigner: true, isWritable: false),
      AccountMeta.fromBase58(
        systemProgramId,
        isSigner: false,
        isWritable: false,
      ),
    ],
    data: Uint8List.view(data.buffer),
  );
}

SolanaInstruction createCompleteUnstakeIx({
  required String pool,
  required String mint,
  required String user,
  required String tokenProgramId,
}) {
  final userStake = deriveUserStakePDA(pool, user);
  final tokenVault = deriveTokenVaultPDA(pool);
  final userToken = deriveATA(user, mint, tokenProgramId);
  final metadata = derivePoolMetadataPDA(pool);

  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [
      AccountMeta.fromBase58(pool, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(userStake, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(tokenVault, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(userToken, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(mint, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(user, isSigner: true, isWritable: true),
      AccountMeta.fromBase58(
        tokenProgramId,
        isSigner: false,
        isWritable: false,
      ),
      AccountMeta.fromBase58(
        systemProgramId,
        isSigner: false,
        isWritable: false,
      ),
      // Metadata PDA: required since chiefstaker 91ce912 — decrements
      // member_count if completing a full unstake closes the account.
      AccountMeta.fromBase58(metadata, isSigner: false, isWritable: true),
    ],
    data: Uint8List.fromList([StakerInstruction.completeUnstake]),
  );
}

SolanaInstruction createCancelUnstakeRequestIx({
  required String pool,
  required String user,
}) {
  final userStake = deriveUserStakePDA(pool, user);

  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [
      AccountMeta.fromBase58(pool, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(userStake, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(user, isSigner: true, isWritable: false),
      AccountMeta.fromBase58(
        systemProgramId,
        isSigner: false,
        isWritable: false,
      ),
    ],
    data: Uint8List.fromList([StakerInstruction.cancelUnstakeRequest]),
  );
}

SolanaInstruction createClaimRewardsIx({
  required String pool,
  required String user,
}) {
  final userStake = deriveUserStakePDA(pool, user);

  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [
      AccountMeta.fromBase58(pool, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(userStake, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(user, isSigner: true, isWritable: true),
      AccountMeta.fromBase58(
        systemProgramId,
        isSigner: false,
        isWritable: false,
      ),
    ],
    data: Uint8List.fromList([StakerInstruction.claimRewards]),
  );
}

SolanaInstruction createUnstakeIx({
  required String pool,
  required String mint,
  required String user,
  required BigInt amount,
  required String tokenProgramId,
}) {
  final userStake = deriveUserStakePDA(pool, user);
  final tokenVault = deriveTokenVaultPDA(pool);
  final userToken = deriveATA(user, mint, tokenProgramId);
  final metadata = derivePoolMetadataPDA(pool);

  final data = ByteData(1 + 8);
  data.setUint8(0, StakerInstruction.unstake);
  data.setUint64(1, amount.toInt(), Endian.little);

  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [
      AccountMeta.fromBase58(pool, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(userStake, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(tokenVault, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(userToken, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(mint, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(user, isSigner: true, isWritable: true),
      AccountMeta.fromBase58(
        tokenProgramId,
        isSigner: false,
        isWritable: false,
      ),
      AccountMeta.fromBase58(
        systemProgramId,
        isSigner: false,
        isWritable: false,
      ),
      // Metadata PDA: required since chiefstaker 91ce912 — decrements
      // member_count if a full unstake closes the account.
      AccountMeta.fromBase58(metadata, isSigner: false, isWritable: true),
    ],
    data: Uint8List.view(data.buffer),
  );
}

SolanaInstruction createCloseStakeAccountIx({
  required String pool,
  required String user,
}) {
  final userStake = deriveUserStakePDA(pool, user);
  final metadata = derivePoolMetadataPDA(pool);

  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [
      AccountMeta.fromBase58(pool, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(userStake, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(user, isSigner: true, isWritable: true),
      // Metadata PDA: required since chiefstaker 91ce912 — decrements
      // member_count on close.
      AccountMeta.fromBase58(metadata, isSigner: false, isWritable: true),
    ],
    data: Uint8List.fromList([StakerInstruction.closeStakeAccount]),
  );
}

SolanaInstruction createDepositRewardsIx({
  required String pool,
  required String depositor,
  required BigInt amount,
}) {
  final data = ByteData(1 + 8);
  data.setUint8(0, StakerInstruction.depositRewards);
  data.setUint64(1, amount.toInt(), Endian.little);

  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [
      AccountMeta.fromBase58(pool, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(depositor, isSigner: true, isWritable: true),
      AccountMeta.fromBase58(
        systemProgramId,
        isSigner: false,
        isWritable: false,
      ),
    ],
    data: Uint8List.view(data.buffer),
  );
}

SolanaInstruction createUpdatePoolSettingsIx({
  required String pool,
  required String authority,
  BigInt? minStakeAmount,
  BigInt? lockDurationSeconds,
  BigInt? unstakeCooldownSeconds,
}) {
  final buf = BytesBuilder();
  buf.addByte(StakerInstruction.updatePoolSettings);
  for (final val in [
    minStakeAmount,
    lockDurationSeconds,
    unstakeCooldownSeconds,
  ]) {
    if (val != null) {
      buf.addByte(1);
      final d = ByteData(8);
      d.setUint64(0, val.toInt(), Endian.little);
      buf.add(Uint8List.view(d.buffer));
    } else {
      buf.addByte(0);
    }
  }

  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [
      AccountMeta.fromBase58(pool, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(authority, isSigner: true, isWritable: false),
    ],
    data: buf.toBytes(),
  );
}

SolanaInstruction createSyncPoolIx({required String pool}) {
  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [AccountMeta.fromBase58(pool, isSigner: false, isWritable: true)],
    data: Uint8List.fromList([StakerInstruction.syncPool]),
  );
}

SolanaInstruction createSyncRewardsIx({required String pool}) {
  return SolanaInstruction.fromBase58(
    programId: chiefStakerProgramId,
    accounts: [AccountMeta.fromBase58(pool, isSigner: false, isWritable: true)],
    data: Uint8List.fromList([StakerInstruction.syncRewards]),
  );
}
