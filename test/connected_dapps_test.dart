import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/connected_dapps.dart';

class _Client implements LibwalletClient, Transport {
  final revoked = <String>[];

  @override
  late final web3Connections = Web3ConnectionApi(this);
  @override
  late final walletConnect = WalletConnectApi(this);

  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    switch (path) {
      case 'Web3/Connection':
        return [
          for (final id in ['selected', 'other'])
            {
              'Id': 'grant-$id',
              'Host': 'https://$id.test',
              'Account': id,
              'Created': '2026-11-01T00:00:00Z',
            },
        ];
      case 'WalletConnect:sessions':
        return [
          for (final (topic, state, address) in [
            ('selected-session', 'active', '0xAbC'),
            ('other-session', 'active', '0xDef'),
            ('pending-session', 'proposed', '0xAbC'),
          ])
            {
              'Topic': topic,
              'State': state,
              'PeerMetadata': {'name': topic},
              'Namespaces': {
                'eip155': {
                  'accounts': ['eip155:1:$address'],
                },
              },
            },
        ];
      case 'WalletConnect:disconnect':
        revoked.add(params!['Topic'] as String);
        return null;
      default:
        if (verb == 'DELETE' && path.startsWith('Web3/Connection/')) {
          revoked.add(path.split('/').last);
          return null;
        }
        throw StateError('Unexpected request: $path');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'only revokes browser grants and active sessions for the selected wallet',
    () async {
      final client = _Client();
      final entries = await listConnectedDapps(client, const [
        (id: 'selected', chain: 'ethereum', address: '0xabc'),
      ]);
      expect(entries.map((entry) => entry.id), [
        'grant-selected',
        'selected-session',
      ]);
      for (final entry in entries) {
        await entry.revoke(client);
      }
      expect(client.revoked, ['grant-selected', 'selected-session']);
    },
  );

  test('Solana addresses match exactly, and expired sessions are ignored', () {
    WcSession session(String address, DateTime? expiry) => WcSession(
      id: 'session',
      topic: 'topic',
      pairingTopic: '',
      state: 'active',
      peerMetadata: const {},
      namespaces: {
        'solana': {
          'accounts': ['solana:mainnet:$address'],
        },
      },
      expiry: expiry,
    );
    const accounts = [(id: 'selected', chain: 'solana', address: 'AbC')];
    expect(
      walletConnectSessionMatches(session('abc', null), accounts),
      isFalse,
    );
    expect(
      walletConnectSessionMatches(session('AbC', DateTime.utc(2020)), accounts),
      isFalse,
    );
    expect(walletConnectSessionMatches(session('AbC', null), accounts), isTrue);
  });
}
