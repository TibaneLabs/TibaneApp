/// SPL Token program instruction builders (burn, close, ATA creation)
library;

import 'dart:typed_data';

import '../constants/solana_constants.dart';
import 'solana_common.dart';

/// Derive the Associated Token Account address
String deriveATA(String owner, String mint, String tokenProgramId) {
  final (ata, _) = findProgramAddressFromStrings([
    base58Decode(owner),
    base58Decode(tokenProgramId),
    base58Decode(mint),
  ], associatedTokenProgramId);
  return ata;
}

/// Create an idempotent ATA creation instruction
SolanaInstruction createAssociatedTokenAccountIdempotentIx({
  required String payer,
  required String owner,
  required String mint,
  required String tokenProgramId,
}) {
  final ata = deriveATA(owner, mint, tokenProgramId);
  return SolanaInstruction.fromBase58(
    programId: associatedTokenProgramId,
    accounts: [
      AccountMeta.fromBase58(payer, isSigner: true, isWritable: true),
      AccountMeta.fromBase58(ata, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(owner, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(mint, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(systemProgramId, isSigner: false, isWritable: false),
      AccountMeta.fromBase58(tokenProgramId, isSigner: false, isWritable: false),
    ],
    data: Uint8List.fromList([1]), // 1 = CreateIdempotent
  );
}

/// SPL Token BurnChecked instruction
SolanaInstruction createBurnCheckedIx({
  required String tokenAccount,
  required String mint,
  required String authority,
  required BigInt amount,
  required int decimals,
  required String tokenProgramId,
}) {
  // Instruction index 15 = BurnChecked
  final data = ByteData(1 + 8 + 1);
  data.setUint8(0, 15);
  data.setUint64(1, amount.toInt(), Endian.little);
  data.setUint8(9, decimals);

  return SolanaInstruction.fromBase58(
    programId: tokenProgramId,
    accounts: [
      AccountMeta.fromBase58(tokenAccount, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(mint, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(authority, isSigner: true, isWritable: false),
    ],
    data: Uint8List.view(data.buffer),
  );
}

/// SPL Token CloseAccount instruction
SolanaInstruction createCloseAccountIx({
  required String tokenAccount,
  required String destination,
  required String authority,
  required String tokenProgramId,
}) {
  return SolanaInstruction.fromBase58(
    programId: tokenProgramId,
    accounts: [
      AccountMeta.fromBase58(tokenAccount, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(destination, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(authority, isSigner: true, isWritable: false),
    ],
    data: Uint8List.fromList([9]), // 9 = CloseAccount
  );
}

/// SystemProgram transfer instruction
SolanaInstruction createSystemTransferIx({
  required String from,
  required String to,
  required BigInt lamports,
}) {
  // SystemProgram.Transfer = instruction index 2, then u64 lamports
  final data = ByteData(4 + 8);
  data.setUint32(0, 2, Endian.little);
  data.setUint64(4, lamports.toInt(), Endian.little);

  return SolanaInstruction.fromBase58(
    programId: systemProgramId,
    accounts: [
      AccountMeta.fromBase58(from, isSigner: true, isWritable: true),
      AccountMeta.fromBase58(to, isSigner: false, isWritable: true),
    ],
    data: Uint8List.view(data.buffer),
  );
}

/// Build burn + close instructions for a token account.
/// Returns a list of instructions (1 or 2 depending on whether burn is needed).
List<SolanaInstruction> buildBurnAndCloseInstructions({
  required String tokenAccount,
  required String mint,
  required String owner,
  required BigInt amount,
  required int decimals,
  required bool isToken2022,
}) {
  final tokenProgramId = isToken2022 ? token2022ProgramId : splTokenProgramId;
  final instructions = <SolanaInstruction>[];

  // Burn tokens if amount > 0
  if (amount > BigInt.zero) {
    instructions.add(createBurnCheckedIx(
      tokenAccount: tokenAccount,
      mint: mint,
      authority: owner,
      amount: amount,
      decimals: decimals,
      tokenProgramId: tokenProgramId,
    ));
  }

  // Close the account to reclaim rent
  instructions.add(createCloseAccountIx(
    tokenAccount: tokenAccount,
    destination: owner,
    authority: owner,
    tokenProgramId: tokenProgramId,
  ));

  return instructions;
}
