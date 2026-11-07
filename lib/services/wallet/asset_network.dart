import 'package:libwallet/libwallet.dart' show Asset, Network;

/// LibWallet assets may identify their network by its ID or chain key.
bool assetBelongsToNetwork(Asset asset, Network network) {
  return asset.network == network.id ||
      asset.network == '${network.type.name}.${network.chainId}';
}
