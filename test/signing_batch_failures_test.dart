import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/utils/wallet_error.dart';

class _Transport implements Transport {
  final paths = <String>[];
  bool fail = true;
  void Function()? afterFirst;

  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    paths.add(path);
    if (fail && paths.length == 2) throw StateError('fixture signing failure');
    afterFirst?.call();
    if (path.endsWith(':signAndSendTransaction')) {
      return {'signature': 'fixture-signature-${paths.length}'};
    }
    return {
      'transaction': base64Encode([1, 2, 3]),
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  _Client(Transport transport) : accounts = AccountApi(transport);
  @override
  final AccountApi accounts;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(this.client);
  final LibwalletClient client;
  String source = 'fixture-account';
  @override
  String get accountId => source;
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

void main() {
  late _Transport transport;
  late _Backend backend;
  late List<SigningKey> keys;
  final transactions = List.generate(3, (i) => Uint8List.fromList([i]));

  setUp(() {
    transport = _Transport();
    backend = _Backend(_Client(transport));
    keys = [const SigningKey(id: 'test', key: 'test', type: 'Password')];
    backend.registerSigningAuthorization(keys, backend.signingContext);
  });
  tearDown(() => backend.dispose());

  test(
    'sign-only failure propagates and never silently returns a null entry',
    () async {
      await expectLater(
        backend.signTransactionsWithKeys(transactions, keys),
        throwsStateError,
      );
      expect(transport.paths, hasLength(2));
      expect(backend.error, contains('signing failure'));
    },
  );

  test(
    'partial submission reports committed signatures and stops the batch',
    () async {
      await expectLater(
        backend.signAndSendTransactionsWithKeys(transactions, keys),
        throwsA(
          isA<PartialBroadcastException>()
              .having((e) => e.submitted, 'submitted', ['fixture-signature-1'])
              .having(
                (e) => WalletError.from(e).key,
                'friendly error',
                WalletErrorKey.partialBroadcast,
              ),
        ),
      );
      expect(transport.paths, hasLength(2));
    },
  );

  test(
    'switching accounts after authorization prevents all native calls',
    () async {
      backend.source = 'another-account';
      await expectLater(
        backend.signTransactionsWithKeys(transactions, keys),
        throwsStateError,
      );
      expect(transport.paths, isEmpty);
    },
  );

  test(
    'switching accounts between batch items prevents further submissions',
    () async {
      transport.fail = false;
      transport.afterFirst = () => backend.source = 'another-account';
      await expectLater(
        backend.signAndSendTransactionsWithKeys(transactions, keys),
        throwsA(isA<PartialBroadcastException>()),
      );
      expect(transport.paths, hasLength(1));
      expect(transport.paths.single, startsWith('Account/fixture-account:'));
    },
  );
}
