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
      return 'assets/icons/solana-sol-logo-orange-network.png';
    case NetworkType.evm:
      switch (net.chainId) {
        case '1':
          return 'assets/icons/ethereum-eth-logo-orange-network.png';
        case '56':
          return 'assets/icons/bnb-bnb-logo-orange-network.png';
        case '137':
          return 'assets/icons/polygon-matic-logo-orange-network.png';
        default:
          return null;
      }
    case NetworkType.bitcoin:
      switch (net.currencySymbol.toUpperCase()) {
        case 'LTC':
          return 'assets/icons/litecoin-ltc-logo-orange-network.png';
        case 'DOGE':
          return 'assets/icons/dogecoin-doge-logo-orange-network.png';
        default:
          return null;
      }
    case NetworkType.unknown:
      return null;
  }
}
