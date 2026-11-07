import 'coinbase_spot_price_service.dart';

/// Keeps the ETH price dependency injectable for existing wallet callers.
class EthUsdPriceService extends CoinbaseSpotPriceService {
  EthUsdPriceService({super.client, super.endpoint}) : super(symbol: 'ETH');
}
