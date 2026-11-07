import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/services/wallet/web3_request_coordinator.dart';

class _Transport implements Transport {
  final calls = <Map<String, dynamic>>[];
  final rejected = <String>[];
  final gates = <Completer<dynamic>>[];
  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    if (path == 'Web3:request') {
      calls.add(params!);
      final gate = Completer<dynamic>();
      gates.add(gate);
      return gate.future;
    }
    if (path.endsWith(':reject')) {
      rejected.add(path);
      return {'Id': path, 'Type': 'connect', 'Status': 'rejected'};
    }
    throw StateError('Unexpected request: $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  final transport = _Transport();
  final pending = StreamController<PendingRequest>.broadcast();
  @override
  late final web3 = Web3Api(transport);
  @override
  late final requests = RequestApi(transport);
  @override
  Stream<PendingRequest> get pendingRequests => pending.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'pending approvals stay with their source and web3 transports are serialized',
    () async {
      final client = _Client();
      final coordinator = Web3RequestCoordinator.forClient(client);
      addTearDown(() async {
        Web3RequestCoordinator.disposeFor(client);
        await client.pending.close();
      });
      final approvals = <String>[];
      final first = coordinator.request(
        origin: 'https://first.test',
        query: {'method': 'eth_accounts'},
        isCurrent: () => true,
        approve: (request) async => approvals.add(request.id),
      );
      final second = coordinator.request(
        origin: 'https://second.test',
        query: {'method': 'eth_accounts'},
        isCurrent: () => true,
        approve: (request) async => approvals.add('second-${request.id}'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.transport.calls, hasLength(1));
      client.pending.add(
        PendingRequest.fromJson({
          'Id': 'foreign',
          'Type': 'connect',
          'Status': 'pending',
          'Host': 'https://second.test',
        }),
      );
      client.pending.add(
        PendingRequest.fromJson({
          'Id': 'own',
          'Type': 'connect',
          'Status': 'pending',
          'Host': 'https://first.test',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(approvals, ['own']);
      expect(client.transport.rejected, hasLength(1));
      client.transport.gates.first.complete(['first-account']);
      expect(await first, ['first-account']);
      await Future<void>.delayed(Duration.zero);
      expect(client.transport.calls, hasLength(2));
      client.transport.gates.last.complete(['second-account']);
      expect(await second, ['second-account']);
    },
  );

  test(
    'a queued request from an old document never reaches the native client',
    () async {
      final client = _Client();
      final coordinator = Web3RequestCoordinator.forClient(client);
      addTearDown(() async {
        Web3RequestCoordinator.disposeFor(client);
        await client.pending.close();
      });
      final first = coordinator.request(
        origin: 'https://first.test',
        query: {},
        isCurrent: () => true,
        approve: (_) async {},
      );
      var current = true;
      final second = coordinator.request(
        origin: 'https://second.test',
        query: {},
        isCurrent: () => current,
        approve: (_) async {},
      );
      final rejected = expectLater(second, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      current = false;
      client.transport.gates.first.complete(null);
      await first;
      await rejected;
      expect(client.transport.calls, hasLength(1));
    },
  );
}
