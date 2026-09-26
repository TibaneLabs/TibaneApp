import 'package:libwallet/libwallet.dart' show Network, NetworkType;

/// Bundled brand-logo asset for [net], or `null` when we don't ship
/// one. Used by:
///   - the Networks list (one icon per network row),
///   - the dashboard's native-token row (so the row matches the
///     active-network chip's iconography).
/// Map kept here so both call sites stay in sync — divergence between
/// "this is what the network icon looks like" and "this is what the
/// native token icon looks like" would be confusing.
String? networkLogoAsset(Network net) {
  switch (net.type) {
    case NetworkType.solana:
      return networkLogoAssetForChain('solana');
    case NetworkType.evm:
      switch (net.chainId) {
        case '1':
          return networkLogoAssetForChain('ethereum');
        case '56':
          return 'assets/icons/bnb-bnb-logo-orange-network.png';
        case '137':
          return 'assets/icons/polygon-matic-logo-orange-network.png';
        default:
          return null;
      }
    case NetworkType.bitcoin:
      switch (net.currencySymbol.toUpperCase()) {
        case 'BTC':
          return networkLogoAssetForChain('bitcoin');
        case 'BCH':
          return networkLogoAssetForChain('bitcoin-cash');
        case 'LTC':
          return networkLogoAssetForChain('litecoin');
        case 'DOGE':
          return networkLogoAssetForChain('dogecoin');
        default:
          return null;
      }
    case NetworkType.unknown:
      return null;
  }
}

String? networkLogoAssetForChain(String chain) {
  switch (chain) {
    case 'solana':
      return 'assets/icons/sol.png';
    case 'ethereum':
      return 'assets/icons/ethereum.png';
    case 'bitcoin':
      return 'assets/icons/bitcoin.png';
    case 'bitcoin-cash':
      return 'assets/icons/bitcoin-cash.png';
    case 'dogecoin':
      return 'assets/icons/dogecoin.png';
    case 'litecoin':
      return 'assets/icons/litecoin.png';
    default:
      return null;
  }
}
