/// NFT burn instruction builders (regular Metaplex NFTs and compressed NFTs)
library;

import 'dart:typed_data';

import '../constants/solana_constants.dart';
import '../models/token_account.dart';
import 'solana_common.dart';

/// Derive the Metaplex metadata PDA for a given mint
String findMetadataPda(String mint) {
  final (addr, _) = findProgramAddressFromStrings([
    Uint8List.fromList('metadata'.codeUnits),
    base58Decode(metaplexProgramId),
    base58Decode(mint),
  ], metaplexProgramId);
  return addr;
}

/// Derive the Metaplex edition PDA for a given mint
String findEditionPda(String mint) {
  final (addr, _) = findProgramAddressFromStrings([
    Uint8List.fromList('metadata'.codeUnits),
    base58Decode(metaplexProgramId),
    base58Decode(mint),
    Uint8List.fromList('edition'.codeUnits),
  ], metaplexProgramId);
  return addr;
}

/// Derive the Bubblegum tree authority PDA
String findTreeAuthorityPda(String merkleTree) {
  final (addr, _) = findProgramAddressFromStrings([
    base58Decode(merkleTree),
  ], bubblegumProgramId);
  return addr;
}

/// Build a regular NFT burn instruction (Metaplex Burn, discriminator [18])
SolanaInstruction buildRegularNftBurnIx(NftItem nft, String owner) {
  final mint = nft.mint!;
  final metadata = findMetadataPda(mint);
  final edition = findEditionPda(mint);

  // Derive the owner's token account for this mint
  final tokenAccount = nft.tokenAccount ??
      _deriveNftTokenAccount(owner, mint);

  return SolanaInstruction.fromBase58(
    programId: metaplexProgramId,
    accounts: [
      AccountMeta.fromBase58(metadata, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(owner, isSigner: true, isWritable: true),
      AccountMeta.fromBase58(mint, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(tokenAccount, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(edition, isSigner: false, isWritable: true),
      AccountMeta.fromBase58(splTokenProgramId, isSigner: false, isWritable: false),
    ],
    data: Uint8List.fromList([18]), // Burn discriminator
  );
}

/// Build a compressed NFT (cNFT) burn instruction via Bubblegum
SolanaInstruction buildCnftBurnIx(NftItem nft, String owner, Map<String, dynamic> proof) {
  final treeAddress = nft.treeAddress!;
  final treeAuthority = findTreeAuthorityPda(treeAddress);

  final root = base58Decode(proof['root'] as String);
  final dataHash = base58Decode(nft.dataHash!);
  final creatorHash = base58Decode(nft.creatorHash!);
  final leafIndex = nft.leafIndex!;

  // Build instruction data: 8 disc + 32 root + 32 dataHash + 32 creatorHash + 8 nonce + 4 index = 116 bytes
  final data = BytesBuilder();
  data.add(bubblegumBurnDiscriminator);
  data.add(root);
  data.add(dataHash);
  data.add(creatorHash);

  // nonce as u64 LE (same as leaf_id)
  final nonceData = ByteData(8);
  nonceData.setUint64(0, leafIndex, Endian.little);
  data.add(Uint8List.view(nonceData.buffer));

  // index as u32 LE
  final indexData = ByteData(4);
  indexData.setUint32(0, leafIndex, Endian.little);
  data.add(Uint8List.view(indexData.buffer));

  // Accounts
  final accounts = <AccountMeta>[
    AccountMeta.fromBase58(treeAuthority, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(owner, isSigner: true, isWritable: false),
    AccountMeta.fromBase58(owner, isSigner: false, isWritable: false), // leaf delegate = owner
    AccountMeta.fromBase58(treeAddress, isSigner: false, isWritable: true),
    AccountMeta.fromBase58(logWrapperProgramId, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(compressionProgramId, isSigner: false, isWritable: false),
    AccountMeta.fromBase58(systemProgramId, isSigner: false, isWritable: false),
  ];

  // Append proof nodes as remaining accounts
  final proofNodes = proof['proof'] as List;
  for (final node in proofNodes) {
    accounts.add(AccountMeta.fromBase58(node as String, isSigner: false, isWritable: false));
  }

  return SolanaInstruction(
    programId: base58Decode(bubblegumProgramId),
    accounts: accounts,
    data: data.toBytes(),
  );
}

/// Derive ATA for an NFT (SPL Token only, decimals=0)
String _deriveNftTokenAccount(String owner, String mint) {
  final (ata, _) = findProgramAddressFromStrings([
    base58Decode(owner),
    base58Decode(splTokenProgramId),
    base58Decode(mint),
  ], associatedTokenProgramId);
  return ata;
}
