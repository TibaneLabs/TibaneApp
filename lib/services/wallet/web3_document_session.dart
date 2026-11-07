import 'dart:convert';
import 'dart:math';

import 'web3_origin.dart';

class Web3DocumentSession {
  Web3DocumentSession(String url)
    : origin = _secureOrigin(url),
      token = base64UrlEncode(
        List.generate(32, (_) => Random.secure().nextInt(256)),
      );
  final String? origin;
  final String token;

  static String? _secureOrigin(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                const [
                  'localhost',
                  '127.0.0.1',
                  '::1',
                  '[::1]',
                ].contains(uri.host)))) {
      return null;
    }
    return web3SecurityOrigin(url);
  }

  Map<String, dynamic>? accept(String message) {
    if (origin == null || message.length > 512 * 1024) return null;
    try {
      final envelope = jsonDecode(message);
      if (envelope is! Map || envelope['document'] != token) return null;
      final request = envelope['request'];
      if (request is! Map<String, dynamic>) return null;
      final id = request['id'];
      if (!(id is int && id.abs() <= 9007199254740991) &&
          !(id is String && id.length <= 128)) {
        return null;
      }
      final method = request['method'];
      if (method is! String ||
          !RegExp(r'^[a-zA-Z0-9_]{1,128}$').hasMatch(method)) {
        return null;
      }
      final params = request['params'];
      if (params != null && params is! List && params is! Map) return null;
      return request;
    } catch (_) {
      return null;
    }
  }

  /// The raw platform channel exists in subframes too. Only the main-frame
  /// closure receives this unguessable capability; no token is put on window.
  String inject(String providerScript, String rawBridge, String proxyBridge) =>
      '''
(() => {
  if (window !== window.top || location.origin !== ${jsonEncode(origin)}) return;
  const documentToken = ${jsonEncode(token)};
  const nativeBridge = window[${jsonEncode(rawBridge)}];
  const forward = (message) => {
    const request = JSON.parse(message);
    nativeBridge.postMessage(JSON.stringify({document: documentToken, request}));
  };
  Object.defineProperty(window, ${jsonEncode(proxyBridge)}, {
    value: Object.freeze({postMessage: forward}), configurable: true
  });
  Object.defineProperty(window, '__tibaneIsDocument', {
    value: (value) => value === documentToken, configurable: true
  });
  $providerScript
})();
''';

  String resolve(dynamic id, String payload) =>
      guarded('__libwalletResolve(${jsonEncode(id)}, ${jsonEncode(payload)})');

  String guarded(String expression) =>
      '''
(() => {
  if (window === window.top && location.origin === ${jsonEncode(origin)} &&
      typeof window.__tibaneIsDocument === 'function' &&
      window.__tibaneIsDocument(${jsonEncode(token)})) {
    $expression;
  }
})();
''';
}
