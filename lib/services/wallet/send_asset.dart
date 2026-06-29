/// Build the libwallet asset key for a send (Atonline-parity §4.6, Phase 5a).
///
/// Returns null when [mint] is null/empty — the native-asset path, where
/// libwallet sends the current network's native currency. Otherwise
/// `"<networkType>.<chainId>.<mint>"`, the same key format libwallet's
/// `getAssets()` returns (e.g. `solana.mainnet.<mint>`, `ethereum.1.<contract>`).
///
/// For a Solana account this yields exactly the previous hardcoded
/// `solana.mainnet.<mint>` (networkType `solana`, chainId `mainnet`), so the
/// Solana path is unchanged; other chains get the correct per-chain key.
String? sendAssetKey({
  required String? mint,
  required String networkType,
  required String chainId,
}) {
  if (mint == null || mint.isEmpty) return null;
  return '$networkType.$chainId.$mint';
}

/// Native-currency decimals by chain family — the scale for a native send.
/// Solana lamports = 9, EVM wei = 18, Bitcoin sats = 8. Unknown defaults to
/// Solana's 9 (Tibane is Solana-first). Derived from the network TYPE, not
/// `Network.currencyDecimals`, which is unreliable (a stale/default cached
/// network has reported 18 for Solana — mis-scaling a SOL send by 1e9).
int nativeDecimalsForType(String networkType) {
  switch (networkType) {
    case 'evm':
    case 'ethereum':
      return 18;
    case 'bitcoin':
      return 8;
    case 'solana':
    default:
      return 9;
  }
}

/// Extract the bare mint/contract from a libwallet asset key
/// (`"<type>.<chainId>.<mint>"`), so a token sourced from `getAssets()` can be
/// stored as a `mint` and rebuilt with [sendAssetKey]. Returns the segment
/// after the last `.`; empty string for a malformed key.
String mintFromAssetKey(String assetKey) {
  final i = assetKey.lastIndexOf('.');
  if (i < 0 || i == assetKey.length - 1) return '';
  return assetKey.substring(i + 1);
}
