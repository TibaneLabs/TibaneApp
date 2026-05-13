/// SNS (Solana Name Service) domain delete instruction builder
library;

import 'dart:typed_data';

import '../constants/solana_constants.dart';
import 'solana_common.dart';

/// Build a domain delete instruction (Name Service discriminator [3])
SolanaInstruction buildDomainDeleteIx({
  required String nameAccount,
  required String owner,
}) {
  return SolanaInstruction.fromBase58(
    programId: nameServiceProgramId,
    accounts: [
      AccountMeta.fromBase58(nameAccount, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(owner, isSigner: true, isWritable: false),
      AccountMeta.fromBase58(owner, isSigner: false, isWritable: true), // refund target
    ],
    data: Uint8List.fromList([3]), // Delete discriminator
  );
}
