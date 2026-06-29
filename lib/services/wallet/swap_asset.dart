import 'package:libwallet/libwallet.dart' show NetworkType;

import '../../constants/solana_constants.dart' show wsolMint;

/// Chain-aware swap token helpers (Atonline-parity §4.6, Phase 5b). Pure +
/// top-level so the OKX token-ref construction is unit-testable without a
/// client. Keeps the Solana path byte-identical (native = wSOL → 'NATIVE').

/// The mint value the swap UI uses for the current chain's native asset:
/// Solana keeps the wSOL mint (unchanged — that's how the Jupiter holdings +
/// icon already represent native SOL); other chains use the OKX `'NATIVE'`
/// sentinel directly as the row's mint.
const String evmNativeSwapMint = 'NATIVE';

/// The native-asset mint sentinel for [type]'s swap rows.
String nativeSwapMint(NetworkType type) =>
    type == NetworkType.solana ? wsolMint : evmNativeSwapMint;

/// OKX swap token address for a selected [mint]: `'NATIVE'` for the chain's
/// native asset (per [nativeMint]), else the mint/contract unchanged. Matches
/// OKX's convention — `'NATIVE'` for native on BOTH Solana and EVM, the
/// contract/mint otherwise.
String swapTokenAddress(String mint, {required String nativeMint}) =>
    mint == nativeMint ? 'NATIVE' : mint;

/// Whether [mint] is the current chain's native asset.
bool isNativeSwapMint(String mint, {required String nativeMint}) =>
    mint == nativeMint;
