/// PumpFees program instruction builders for fee sharing management
library;

import 'dart:convert';
import 'dart:typed_data';

import '../constants/solana_constants.dart';
import 'solana_common.dart';
import 'spl_instructions.dart';

// ─── PDA derivations ────────────────────────────────────────────────────────

String deriveSharingConfigPda(String mint) {
  final (addr, _) = findProgramAddressFromStrings(
    [utf8.encode('sharing-config'), base58Decode(mint)],
    pumpFeesProgramId,
  );
  return addr;
}

String derivePumpCreatorVaultPda(String sharingConfig) {
  final (addr, _) = findProgramAddressFromStrings(
    [utf8.encode('creator-vault'), base58Decode(sharingConfig)],
    pumpProgramId,
  );
  return addr;
}

String deriveCoinCreatorVaultAuthorityPda(String sharingConfig) {
  final (addr, _) = findProgramAddressFromStrings(
    [utf8.encode('creator_vault'), base58Decode(sharingConfig)],
    pumpSwapAmmProgramId,
  );
  return addr;
}

String deriveBondingCurvePda(String mint) {
  final (addr, _) = findProgramAddressFromStrings(
    [utf8.encode('bonding-curve'), base58Decode(mint)],
    pumpProgramId,
  );
  return addr;
}

String deriveGlobalPda() {
  final (addr, _) = findProgramAddressFromStrings(
    [utf8.encode('global')],
    pumpProgramId,
  );
  return addr;
}

String deriveEventAuthorityPda(String programId) {
  final (addr, _) = findProgramAddressFromStrings(
    [utf8.encode('__event_authority')],
    programId,
  );
  return addr;
}

String derivePoolAuthorityPda(String baseMint) {
  final (addr, _) = findProgramAddressFromStrings(
    [utf8.encode('pool-authority'), base58Decode(baseMint)],
    pumpProgramId,
  );
  return addr;
}

String derivePumpSwapPoolPda(String baseMint) {
  final poolAuthority = derivePoolAuthorityPda(baseMint);
  final indexBuf = Uint8List(2); // u16 LE = 0
  final (addr, _) = findProgramAddressFromStrings(
    [
      utf8.encode('pool'),
      indexBuf,
      base58Decode(poolAuthority),
      base58Decode(baseMint),
      base58Decode(wsolMint),
    ],
    pumpSwapAmmProgramId,
  );
  return addr;
}

// ─── SharingConfig deserialization ──────────────────────────────────────────

class FeeShareHolder {
  final String address;
  final int bps; // basis points (max 2000 = 20%)

  FeeShareHolder({required this.address, required this.bps});

  double get percent => bps / 100.0;
}

class SharingConfig {
  final int bump;
  final int version;
  final int status;
  final String mint;
  final String admin;
  final bool adminRevoked;
  final List<FeeShareHolder> shareholders;

  SharingConfig({
    required this.bump,
    required this.version,
    required this.status,
    required this.mint,
    required this.admin,
    required this.adminRevoked,
    required this.shareholders,
  });

  static SharingConfig? deserialize(Uint8List data) {
    if (data.length < 80) return null;

    // Check discriminator
    for (var i = 0; i < 8; i++) {
      if (data[i] != sharingConfigDiscriminator[i]) return null;
    }

    int offset = 8;
    final bump = data[offset++];
    final version = data[offset++];
    final status = data[offset++];
    final mint = base58Encode(data.sublist(offset, offset + 32)); offset += 32;
    final admin = base58Encode(data.sublist(offset, offset + 32)); offset += 32;
    final adminRevoked = data[offset++] != 0;

    final bd = ByteData.sublistView(data);
    final vecLen = bd.getUint32(offset, Endian.little); offset += 4;

    final shareholders = <FeeShareHolder>[];
    for (var i = 0; i < vecLen; i++) {
      if (offset + 34 > data.length) break;
      final addr = base58Encode(data.sublist(offset, offset + 32)); offset += 32;
      final bps = bd.getUint16(offset, Endian.little); offset += 2;
      shareholders.add(FeeShareHolder(address: addr, bps: bps));
    }

    return SharingConfig(
      bump: bump,
      version: version,
      status: status,
      mint: mint,
      admin: admin,
      adminRevoked: adminRevoked,
      shareholders: shareholders,
    );
  }
}

// ─── Instruction builders ───────────────────────────────────────────────────

/// Create a fee sharing config for a pump.fun token
SolanaInstruction createFeeSharingConfigIx({
  required String payer,
  required String mint,
  bool hasPumpSwapPool = false,
}) {
  final sharingConfig = deriveSharingConfigPda(mint);
  final bondingCurve = deriveBondingCurvePda(mint);
  final global = deriveGlobalPda();
  final pfeesEventAuthority = deriveEventAuthorityPda(pumpFeesProgramId);
  final pumpEventAuthority = deriveEventAuthorityPda(pumpProgramId);

  final accounts = <AccountMeta>[
    AccountMeta.fromBase58(pfeesEventAuthority, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(pumpFeesProgramId, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(payer, isSigner: true, isWritable: true),
    AccountMeta.fromBase58(global, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(mint, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(sharingConfig, isSigner: false, isWritable: true),
    AccountMeta.fromBase58(systemProgramId, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(bondingCurve, isSigner: false, isWritable: true),
    AccountMeta.fromBase58(pumpProgramId, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(pumpEventAuthority, isSigner: false, isWritable: false),
  ];

  if (hasPumpSwapPool) {
    final pool = derivePumpSwapPoolPda(mint);
    final ammEventAuthority = deriveEventAuthorityPda(pumpSwapAmmProgramId);
    accounts.addAll([
      AccountMeta.fromBase58(pool, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(pumpSwapAmmProgramId, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(ammEventAuthority, isSigner: false, isWritable: false),
    ]);
  }

  return SolanaInstruction(
    programId: base58Decode(pumpFeesProgramId),
    accounts: accounts,
    data: Uint8List.fromList(createFeeSharingConfigDisc),
  );
}

/// Update fee shares for a sharing config
SolanaInstruction updateFeeSharesIx({
  required String admin,
  required String mint,
  required List<FeeShareHolder> newShareholders,
  required List<FeeShareHolder> currentShareholders,
}) {
  final sharingConfig = deriveSharingConfigPda(mint);
  final bondingCurve = deriveBondingCurvePda(mint);
  final global = deriveGlobalPda();
  final pfeesEventAuthority = deriveEventAuthorityPda(pumpFeesProgramId);
  final pumpCreatorVault = derivePumpCreatorVaultPda(sharingConfig);
  final pumpEventAuthority = deriveEventAuthorityPda(pumpProgramId);
  final coinCreatorVaultAuth = deriveCoinCreatorVaultAuthorityPda(sharingConfig);
  final coinCreatorVaultAta = deriveATA(coinCreatorVaultAuth, wsolMint, splTokenProgramId);
  final pool = derivePumpSwapPoolPda(mint);
  final ammEventAuthority = deriveEventAuthorityPda(pumpSwapAmmProgramId);

  // Build instruction data: 8 disc + 4 vecLen + [32 addr + 2 bps]*N
  final dataBuilder = BytesBuilder();
  dataBuilder.add(updateFeeSharesDisc);
  final vecLenData = ByteData(4);
  vecLenData.setUint32(0, newShareholders.length, Endian.little);
  dataBuilder.add(Uint8List.view(vecLenData.buffer));
  for (final s in newShareholders) {
    dataBuilder.add(base58Decode(s.address));
    final bpsData = ByteData(2);
    bpsData.setUint16(0, s.bps, Endian.little);
    dataBuilder.add(Uint8List.view(bpsData.buffer));
  }

  final accounts = <AccountMeta>[
    AccountMeta.fromBase58(admin, isSigner: true, isWritable: true),
    AccountMeta.fromBase58(sharingConfig, isSigner: false, isWritable: true),
    AccountMeta.fromBase58(global, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(mint, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(bondingCurve, isSigner: false, isWritable: true),
    AccountMeta.fromBase58(pumpCreatorVault, isSigner: false, isWritable: true),
    AccountMeta.fromBase58(pumpProgramId, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(pumpEventAuthority, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(coinCreatorVaultAuth, isSigner: false, isWritable: true),
    AccountMeta.fromBase58(coinCreatorVaultAta, isSigner: false, isWritable: true),
    AccountMeta.fromBase58(wsolMint, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(splTokenProgramId, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(systemProgramId, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(associatedTokenProgramId, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(pool, isSigner: false, isWritable: true),
    AccountMeta.fromBase58(pumpSwapAmmProgramId, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(ammEventAuthority, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(pfeesEventAuthority, isSigner: false, isWritable: false),
  ];

  // Append current shareholders as remaining accounts (writable for refund)
  for (final s in currentShareholders) {
    accounts.add(AccountMeta.fromBase58(s.address, isSigner: false, isWritable: true));
  }

  return SolanaInstruction(
    programId: base58Decode(pumpFeesProgramId),
    accounts: accounts,
    data: dataBuilder.toBytes(),
  );
}

/// Distribute creator fees (pump bonding curve)
SolanaInstruction distributeCreatorFeesIx({
  required String mint,
  required List<FeeShareHolder> shareholders,
}) {
  final sharingConfig = deriveSharingConfigPda(mint);
  final bondingCurve = deriveBondingCurvePda(mint);
  final pumpCreatorVault = derivePumpCreatorVaultPda(sharingConfig);
  final pumpEventAuthority = deriveEventAuthorityPda(pumpProgramId);

  final accounts = <AccountMeta>[
    AccountMeta.fromBase58(mint, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(bondingCurve, isSigner: false, isWritable: true),
    AccountMeta.fromBase58(sharingConfig, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(pumpCreatorVault, isSigner: false, isWritable: true),
    AccountMeta.fromBase58(systemProgramId, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(pumpEventAuthority, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(pumpProgramId, isSigner: false, isWritable: false),
  ];

  // Append shareholders as remaining accounts
  for (final s in shareholders) {
    accounts.add(AccountMeta.fromBase58(s.address, isSigner: false, isWritable: true));
  }

  return SolanaInstruction(
    programId: base58Decode(pumpProgramId),
    accounts: accounts,
    data: Uint8List.fromList(distributeCreatorFeesDisc),
  );
}

/// Transfer creator fees from PumpSwap AMM pool to pump creator vault
SolanaInstruction transferCreatorFeesToPumpIx({
  required String mint,
}) {
  final sharingConfig = deriveSharingConfigPda(mint);
  final coinCreatorVaultAuth = deriveCoinCreatorVaultAuthorityPda(sharingConfig);
  final coinCreatorVaultAta = deriveATA(coinCreatorVaultAuth, wsolMint, splTokenProgramId);
  final pumpCreatorVault = derivePumpCreatorVaultPda(sharingConfig);
  final ammEventAuthority = deriveEventAuthorityPda(pumpSwapAmmProgramId);

  return SolanaInstruction(
    programId: base58Decode(pumpSwapAmmProgramId),
    accounts: [
      AccountMeta.fromBase58(wsolMint, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(splTokenProgramId, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(systemProgramId, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(associatedTokenProgramId, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(sharingConfig, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(coinCreatorVaultAuth, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(coinCreatorVaultAta, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(pumpCreatorVault, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(ammEventAuthority, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(pumpSwapAmmProgramId, isSigner: false, isWritable: false),
    ],
    data: Uint8List.fromList(transferCreatorFeesToPumpDisc),
  );
}

/// Transfer fee sharing authority to a new admin
SolanaInstruction transferFeeSharingAuthorityIx({
  required String currentAdmin,
  required String newAdmin,
  required String mint,
}) {
  final sharingConfig = deriveSharingConfigPda(mint);
  final pfeesEventAuthority = deriveEventAuthorityPda(pumpFeesProgramId);

  return SolanaInstruction(
    programId: base58Decode(pumpFeesProgramId),
    accounts: [
      AccountMeta.fromBase58(currentAdmin, isSigner: true, isWritable: false),
      AccountMeta.fromBase58(sharingConfig, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(newAdmin, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(pfeesEventAuthority, isSigner: false, isWritable: false),
    ],
    data: Uint8List.fromList(transferFeeSharingAuthorityDisc),
  );
}

/// Revoke fee sharing authority (makes config immutable)
SolanaInstruction revokeFeeSharingAuthorityIx({
  required String admin,
  required String mint,
}) {
  final sharingConfig = deriveSharingConfigPda(mint);
  final pfeesEventAuthority = deriveEventAuthorityPda(pumpFeesProgramId);

  return SolanaInstruction(
    programId: base58Decode(pumpFeesProgramId),
    accounts: [
      AccountMeta.fromBase58(admin, isSigner: true, isWritable: false),
      AccountMeta.fromBase58(sharingConfig, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(pfeesEventAuthority, isSigner: false, isWritable: false),
    ],
    data: Uint8List.fromList(revokeFeeSharingAuthorityDisc),
  );
}
