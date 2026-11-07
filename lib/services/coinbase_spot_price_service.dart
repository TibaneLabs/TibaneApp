import 'dart:convert';

import 'package:http/http.dart' as http;

/// USD spot quote for a native coin. No wallet address is sent to Coinbase.
class CoinbaseSpotPriceService {
  CoinbaseSpotPriceService({
    required this.symbol,
    http.Client? client,
    Uri? endpoint,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _endpoint =
           endpoint ??
           Uri.parse('https://api.coinbase.com/v2/prices/$symbol-USD/spot');

  final String symbol;
  final http.Client _client;
  final bool _ownsClient;
  final Uri _endpoint;

  double? _cachedPrice;
  DateTime? _fetchedAt;
  Future<double>? _inFlight;

  Future<double> getPriceUsd() {
    final fetchedAt = _fetchedAt;
    if (_cachedPrice != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < const Duration(minutes: 3)) {
      return Future.value(_cachedPrice);
    }
    return _inFlight ??= _fetch().whenComplete(() => _inFlight = null);
  }

  Future<double> _fetch() async {
    final response = await _client
        .get(_endpoint)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw StateError(
        '$symbol price request returned HTTP ${response.statusCode}',
      );
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw FormatException('Invalid $symbol price response');
    }
    final data = body['data'];
    if (data is! Map<String, dynamic> ||
        data['base'] != symbol ||
        data['currency'] != 'USD') {
      throw FormatException('Invalid $symbol/USD price pair');
    }
    final price = double.tryParse(data['amount']?.toString() ?? '');
    if (price == null || !price.isFinite || price <= 0) {
      throw FormatException('Invalid $symbol/USD price');
    }
    _cachedPrice = price;
    _fetchedAt = DateTime.now();
    return price;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
