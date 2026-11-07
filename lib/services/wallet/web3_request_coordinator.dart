import 'dart:async';

import 'package:libwallet/libwallet.dart';

import 'web3_origin.dart';

/// LibWallet's pending stream has no document/transport correlation ID. Serialize
/// Web3 calls across browser and WalletConnect, and bind approvals to their
/// originating operation instead of forwarding a global stream to a page.
class Web3RequestCoordinator {
  Web3RequestCoordinator._(this.client) {
    _subscription = client.pendingRequests.listen((request) async {
      if (!request.isPending || !_handled.add(request.id)) return;
      final owner = _owner;
      try {
        if (owner == null ||
            !owner.valid() ||
            (web3SecurityOrigin(request.host) ?? request.host) !=
                (web3SecurityOrigin(owner.origin) ?? owner.origin)) {
          await client.requests.reject(request.id);
        } else {
          await owner.approve(request);
        }
      } catch (_) {
        try {
          await client.requests.reject(request.id);
        } catch (_) {}
      }
    });
  }
  static final _instances = Expando<Web3RequestCoordinator>();
  static Web3RequestCoordinator forClient(LibwalletClient client) =>
      _instances[client] ??= Web3RequestCoordinator._(client);
  static void disposeFor(LibwalletClient client) {
    _instances[client]?._subscription.cancel();
    _instances[client] = null;
  }

  final LibwalletClient client;
  late final StreamSubscription<PendingRequest> _subscription;
  Future<void> _tail = Future.value();
  final Set<String> _handled = {};
  _Web3Owner? _owner;

  Future<dynamic> request({
    required String origin,
    required Map<String, dynamic> query,
    required bool Function() isCurrent,
    required Future<void> Function(PendingRequest) approve,
  }) {
    final result = _tail.then((_) async {
      if (!isCurrent()) throw StateError('wallet_operation_changed');
      _owner = _Web3Owner(origin, isCurrent, approve);
      _handled.clear();
      try {
        return await client.web3.request(origin: origin, query: query);
      } finally {
        _owner = null;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

class _Web3Owner {
  _Web3Owner(this.origin, this.valid, this.approve);
  final String origin;
  final bool Function() valid;
  final Future<void> Function(PendingRequest) approve;
}
