import 'dart:convert';

import 'package:atonline_api/atonline_api.dart';
import 'package:flutter/foundation.dart';

/// Shared AtOnline API instance for all Tibane server interactions.
final tibaneApi = AtOnline(
  'oaap-bapax4-2dgn-b2ze-oquf-bjnuzioy',
  prefix: 'https://www.tibane.net/_rest/',
);

/// Relay service for sponsored transactions.
class RelayService {
  /// Submit a signed transaction to the relay.
  /// Returns the transaction signature on success.
  Future<String> relay(Uint8List signedTransaction) async {
    final b64 = base64Encode(signedTransaction);
    final res = await tibaneApi.req(
      'Crypto/Solana:relay',
      method: 'POST',
      body: {'transaction': b64},
    );
    return res.data['signature'] as String;
  }
}

/// Authentication service using Solana wallet signatures.
/// Flow: solTicket → sign message → solLogin → bearer token stored in AtOnline.
class AuthService {
  /// Whether the user is authenticated (has a valid token)
  bool get isAuthenticated {
    return tibaneApi.tokenV != null &&
        tibaneApi.tokenV!.isNotEmpty &&
        tibaneApi.expiresV > 0;
  }

  /// Get a challenge ticket for the given Solana public key.
  /// Returns (message to sign, ticket identifier).
  Future<({String message, String ticket})> getTicket(String account) async {
    final res = await tibaneApi.req(
      'User:solTicket',
      method: 'POST',
      body: {'account': account, 'client_id': tibaneApi.appId},
    );
    return (
      message: res.data['challenge'] as String,
      ticket: res.data['ticket'] as String,
    );
  }

  /// Login with a signed challenge.
  /// [ticket] is from getTicket, [signature] is the ed25519 signature bytes.
  /// Stores the token in the shared AtOnline instance.
  Future<void> login(String ticket, Uint8List signature) async {
    final sigB64 = base64Encode(signature);
    final payload = '$ticket:$sigB64';
    final res = await tibaneApi.req(
      'User:solLogin',
      method: 'POST',
      body: {'payload': payload, 'client_id': tibaneApi.appId},
    );
    debugPrint('solLogin response: ${res.res}');
    final tokenData = res.data['token'] as Map<String, dynamic>;
    await tibaneApi.storeToken(tokenData);
  }

  /// Clear authentication state
  Future<void> logout() async {
    await tibaneApi.voidToken();
  }
}
