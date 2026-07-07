/// Solana program IDs, seeds, and constants for Tibane Labs
library;

import 'dart:convert';
import 'dart:typed_data';

const heliusRpcUrl = 'https://kristi-cykm4t-fast-mainnet.helius-rpc.com';

// Program IDs
const chiefStakerProgramId = '3Ecf8gyRURyrBtGHS1XAVXyQik5PqgDch4VkxrH4ECcr';
const pumpFeesProgramId = 'pfeeUxB6jkeY1Hxd7CsFCAjcbHA9rWtchMGdZ6VojVZ';
const pumpProgramId = '6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P';
const pumpSwapAmmProgramId = 'pAMMBay6oceH9fJKBRHGP5D4bD4sWpmSwMn52FMfXEA';
const splTokenProgramId = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const token2022ProgramId = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
const associatedTokenProgramId = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';
const metaplexProgramId = 'metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s';
const systemProgramId = '11111111111111111111111111111111';
const sysvarRentId = 'SysvarRent111111111111111111111111111111111';
const wsolMint = 'So11111111111111111111111111111111111111112';
const nameServiceProgramId = 'namesLPneVptA9Z5rqUDD9tMTWEJwofgaYwp8cawRkX';
const bubblegumProgramId = 'BGUMAp9Gq7iTEuizy4pqaxsTyUCBK68MDfK752saRPUY';
const logWrapperProgramId = 'noopb9bkMVfRPU8AsbpTUg8AQkHtKwMYZiFUjNRtMmV';
const compressionProgramId = 'cmtDvXumGCrqC1Age74AVPhSRVXJMd8PJS91L8KbNCK';

// Relayer for sponsored burns
const relayerAddress = 'HSYatVptUXtn4f5JeDBzRhceG5LoMnsL4CizfFjxS83y';

/// WalletConnect Cloud project id. Empty disables WC; set this to a real
/// project id from https://cloud.walletconnect.com to enable v2 pairing.
const walletConnectProjectId = '';

// Tibane Thecat ($ChiefPussy) token
const chiefPussyMint = 'DRtvTCzfiKGhCVREmBbZdN9sB8PHeq9KdRZ3VmFhpump';

// Well-known stablecoin mints (Solana).
const usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const usdtMint = 'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB';

/// Bundled logo assets for well-known mints — offline, crisp, and reliable
/// where metadata servers fall short (e.g. Helius/libwallet return no image for
/// USDT). [TokenIcon] uses these with priority over a network `imageUrl`.
const Map<String, String> kBundledTokenIcons = {
  wsolMint: 'assets/icons/sol.png',
  usdcMint: 'assets/icons/usdc.png',
  usdtMint: 'assets/icons/usdt.png',
  chiefPussyMint: 'assets/icons/chiefp.jpeg',
};

// Account discriminators
final poolDiscriminator = Uint8List.fromList([
  0xc7,
  0x5f,
  0x7e,
  0x2d,
  0x3b,
  0x1a,
  0x9c,
  0x4e,
]);
final userStakeDiscriminator = Uint8List.fromList([
  0xa3,
  0x8b,
  0x5d,
  0x2f,
  0x7c,
  0x4a,
  0x1e,
  0x9d,
]);
final sharingConfigDiscriminator = Uint8List.fromList([
  216,
  74,
  9,
  0,
  56,
  140,
  93,
  75,
]);

// Bubblegum burn discriminator
final bubblegumBurnDiscriminator = Uint8List.fromList([
  116,
  110,
  29,
  56,
  107,
  219,
  42,
  93,
]);

// PumpFees instruction discriminators
final createFeeSharingConfigDisc = Uint8List.fromList([
  195,
  78,
  86,
  76,
  111,
  52,
  251,
  213,
]);
final updateFeeSharesDisc = Uint8List.fromList([
  189,
  13,
  136,
  99,
  187,
  164,
  237,
  35,
]);
final distributeCreatorFeesDisc = Uint8List.fromList([
  165,
  114,
  103,
  0,
  121,
  206,
  247,
  81,
]);
final transferCreatorFeesToPumpDisc = Uint8List.fromList([
  139,
  52,
  134,
  85,
  228,
  229,
  108,
  241,
]);
final transferFeeSharingAuthorityDisc = Uint8List.fromList([
  202,
  10,
  75,
  200,
  164,
  34,
  210,
  96,
]);
final revokeFeeSharingAuthorityDisc = Uint8List.fromList([
  18,
  233,
  158,
  39,
  185,
  207,
  58,
  104,
]);

// Seeds
final poolSeed = utf8.encode('pool');
final stakeSeed = utf8.encode('stake');
final tokenVaultSeed = utf8.encode('token_vault');
final metadataSeed = utf8.encode('metadata');

// Instruction indices
class StakerInstruction {
  static const initializePool = 0;
  static const stake = 1;
  static const unstake = 2;
  static const claimRewards = 3;
  static const depositRewards = 4;
  static const syncPool = 5;
  static const syncRewards = 6;
  static const updatePoolSettings = 7;
  static const transferAuthority = 8;
  static const requestUnstake = 9;
  static const completeUnstake = 10;
  static const cancelUnstakeRequest = 11;
  static const closeStakeAccount = 12;
  static const fixTotalRewardDebt = 13;
  static const setPoolMetadata = 14;
  static const takeFeeOwnership = 15;
  static const stakeOnBehalf = 16;
}

// WAD = 10^18 for fixed-point math
final BigInt wad = BigInt.from(10).pow(18);

/// Shorten a Solana address for display
String shortenAddress(String address, {int chars = 4}) {
  if (address.length <= chars * 2 + 3) return address;
  return '${address.substring(0, chars)}...${address.substring(address.length - chars)}';
}

/// Format lamports to SOL with specified decimals
String formatSol(BigInt lamports, {int decimals = 4}) {
  final sol = lamports.toDouble() / 1e9;
  return sol.toStringAsFixed(decimals);
}

/// Format token amount with decimals
String formatTokenAmount(
  BigInt amount,
  int tokenDecimals, {
  int displayDecimals = 2,
}) {
  final value =
      amount.toDouble() / (BigInt.from(10).pow(tokenDecimals)).toDouble();
  if (value >= 1e9) return '${(value / 1e9).toStringAsFixed(displayDecimals)}B';
  if (value >= 1e6) return '${(value / 1e6).toStringAsFixed(displayDecimals)}M';
  if (value >= 1e3) return '${(value / 1e3).toStringAsFixed(displayDecimals)}K';
  return value.toStringAsFixed(displayDecimals);
}

/// Render a raw token amount with at most [maxDecimals] fractional
/// digits, stripping insignificant trailing zeros (and the dangling
/// `.`). `0.006000000` becomes `0.006`; `1.0` becomes `1`. Use this
/// for transaction rows where libwallet's `Amount.toString()` pads
/// to the full asset exponent and produces noisy decimals.
String formatAmountTrimmed(BigInt value, int exp, {int maxDecimals = 8}) {
  final decimals = exp < maxDecimals ? exp : maxDecimals;
  final divisor = BigInt.from(10).pow(exp);
  final dv = value.toDouble() / divisor.toDouble();
  var s = dv.toStringAsFixed(decimals);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}
