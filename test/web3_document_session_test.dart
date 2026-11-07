import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet/web3_document_session.dart';

void main() {
  test('only the current document capability can submit bridge messages', () {
    final first = Web3DocumentSession('https://example.test/path');
    final next = Web3DocumentSession('https://example.test/other');
    final request = {'id': 1, 'method': 'eth_accounts', 'params': []};
    final valid = jsonEncode({'document': first.token, 'request': request});
    expect(first.accept(valid), request);
    expect(next.accept(valid), isNull);
    expect(first.accept(jsonEncode(request)), isNull);
    expect(
      first.accept(jsonEncode({'document': 'iframe', 'request': request})),
      isNull,
    );
    expect(Web3DocumentSession('file:///tmp/page').accept(valid), isNull);
    expect(Web3DocumentSession('http://example.test').origin, isNull);
    expect(
      Web3DocumentSession('http://localhost:8080').origin,
      'http://localhost:8080',
    );
  });

  test(
    'injection is main-frame-only and response IDs cannot execute JavaScript',
    () async {
      final document = Web3DocumentSession('https://example.test');
      final id = '(()=>{injected=true;return 1})()';
      final script =
          '''
const vm = require('vm');
const make = (main) => {
  const messages = [];
  const window = {raw: {postMessage: (message) => messages.push(message)}};
  window.top = main ? window : {};
  const sandbox = {window, location: {origin: 'https://example.test'}, messages};
  vm.runInNewContext(${jsonEncode(document.inject('window.proxy.postMessage(JSON.stringify({id: 1, method: "eth_accounts"}));', 'raw', 'proxy'))}, sandbox);
  return messages;
};
const sandbox = {injected: false, location: {origin: 'https://example.test'}};
sandbox.window = sandbox; sandbox.top = sandbox;
sandbox.__tibaneIsDocument = (token) => token === ${jsonEncode(document.token)};
sandbox.__libwalletResolve = (id) => { sandbox.returnedId = id; };
vm.runInNewContext(${jsonEncode(document.resolve(id, '{}'))}, sandbox);
process.stdout.write(JSON.stringify({main: make(true), iframe: make(false), injected: sandbox.injected, id: sandbox.returnedId}));
''';
      final result = await Process.run('node', ['-e', script]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final output = jsonDecode(result.stdout as String) as Map;
      expect(output['iframe'], isEmpty);
      expect(output['injected'], false);
      expect(output['id'], id);
      expect(
        document.accept((output['main'] as List).single as String),
        isNotNull,
      );
    },
    testOn: 'mac-os || linux || windows',
  );
}
