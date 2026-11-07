import 'dart:convert';

import 'package:http/http.dart' as http;

/// Native ETH balance until LibWallet includes it in Asset:list.
class EthereumRpcService {
  EthereumRpcService({http.Client? client, Uri? endpoint})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _endpoint =
          endpoint ?? Uri.parse('https://rpc.modchain.net/chain/ethereum/rpc');

  final http.Client _client;
  final bool _ownsClient;
  final Uri _endpoint;

  Future<BigInt> getBalanceWei(String address) async {
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(address)) {
      throw const FormatException('Invalid Ethereum address');
    }
    final response = await _client
        .post(
          _endpoint,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'eth_getBalance',
            'params': [address, 'latest'],
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw StateError('Ethereum RPC returned HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic> || body['error'] != null) {
      throw const FormatException('Ethereum RPC returned an error');
    }
    final hex = body['result'];
    if (hex is! String || !RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(hex)) {
      throw const FormatException('Ethereum RPC returned an invalid balance');
    }
    return BigInt.parse(hex.substring(2), radix: 16);
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
