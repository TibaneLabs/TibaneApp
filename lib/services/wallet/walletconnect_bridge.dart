import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:libwallet/libwallet.dart';

import '../../screens/walletconnect/wc_proposal_sheet.dart';
import 'libwallet_backend.dart';

/// Manages the libwallet WalletConnect v2 relay lifecycle and routes
/// inbound proposals + requests to the appropriate UI / web3 handlers.
/// Created lazily by [LibwalletBackend] the first time the user opens the
/// WalletConnect screen. Stays alive until the app is killed or the user
/// explicitly disconnects everything.
class WalletConnectBridge extends ChangeNotifier {
  WalletConnectBridge({
    required this.client,
    required this.backend,
    required this.rootNavigatorKey,
  });

  final LibwalletClient client;
  final LibwalletBackend backend;
  final GlobalKey<NavigatorState> rootNavigatorKey;

  StreamSubscription<WcSessionProposal>? _propSub;
  StreamSubscription<WcSessionRequest>? _reqSub;
  bool _started = false;
  String? _error;

  bool get isStarted => _started;

  String? get error => _error;

  Future<bool> start({required String projectId}) async {
    if (_started) return true;
    if (projectId.isEmpty) {
      _error = 'WalletConnect project id is not configured';
      notifyListeners();
      return false;
    }
    try {
      await client.walletConnect.start(projectId: projectId);
      _propSub = client.walletConnectProposals.listen(_handleProposal);
      _reqSub = client.walletConnectRequests.listen(_handleRequest);
      _started = true;
      _error = null;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      debugPrint('WalletConnect start failed: $_error');
      notifyListeners();
      return false;
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    await _propSub?.cancel();
    await _reqSub?.cancel();
    _propSub = null;
    _reqSub = null;
    try {
      await client.walletConnect.stop();
    } catch (e) {
      debugPrint('WalletConnect stop failed: $e');
    }
    _started = false;
    notifyListeners();
  }

  Future<String?> pair(String uri) async {
    try {
      return await client.walletConnect.pair(uri);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<List<WcSession>> sessions() async {
    try {
      return await client.walletConnect.sessions();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return const [];
    }
  }

  Future<void> disconnect(String topic) async {
    try {
      await client.walletConnect.disconnect(topic);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> _handleProposal(WcSessionProposal p) async {
    if (rootNavigatorKey.currentContext == null) {
      await _safeReject(p.pairingTopic, 'No active UI');
      return;
    }
    final accounts = await _enumerateAccounts(p);
    if (accounts.isEmpty) {
      await _safeReject(
        p.pairingTopic,
        'No matching accounts for the requested chains',
      );
      return;
    }
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) {
      await _safeReject(p.pairingTopic, 'No active UI');
      return;
    }
    final result = await showWcSessionProposalSheet(
      // ignore: use_build_context_synchronously
      ctx,
      proposal: p,
      candidateAccounts: accounts,
    );
    if (result == null || result.accounts.isEmpty) {
      await _safeReject(p.pairingTopic, 'User rejected');
      return;
    }
    try {
      await client.walletConnect.approveSession(
        p.pairingTopic,
        accounts: result.accounts,
      );
    } catch (e) {
      debugPrint('approveSession failed: $e');
    }
    notifyListeners();
  }

  Future<void> _safeReject(String pairingTopic, String reason) async {
    try {
      await client.walletConnect.rejectSession(pairingTopic, message: reason);
    } catch (e) {
      debugPrint('rejectSession failed: $e');
    }
  }

  /// Build CAIP-10 strings for our accounts that match any chain the dApp
  /// asked for. Pairs each compatible account with every requested chain.
  Future<List<WcCandidateAccount>> _enumerateAccounts(
    WcSessionProposal p,
  ) async {
    final out = <WcCandidateAccount>[];
    try {
      final accounts = await client.accounts.list();
      final wanted = _requestedNamespaces(p);
      for (final acct in accounts) {
        final ns = _accountNamespace(acct.type);
        if (ns == null) continue;
        final chains = wanted[ns];
        if (chains == null || chains.isEmpty) continue;
        for (final chain in chains) {
          out.add(
            WcCandidateAccount(
              accountId: acct.id,
              address: acct.address,
              chainId: chain,
              type: acct.type,
              namespace: ns,
              caip10: '$chain:${acct.address}',
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('enumerateAccounts failed: $e');
    }
    return out;
  }

  /// Union of required + optional namespaces → list of requested chains.
  Map<String, List<String>> _requestedNamespaces(WcSessionProposal p) {
    final out = <String, List<String>>{};
    void absorb(dynamic raw) {
      if (raw is! Map) return;
      raw.forEach((ns, spec) {
        if (spec is! Map) return;
        final chains =
            (spec['chains'] as List?)?.whereType<String>().toList() ?? const [];
        if (chains.isEmpty) return;
        (out[ns as String] ??= <String>[]).addAll(chains);
      });
    }

    absorb(p.proposal['requiredNamespaces']);
    absorb(p.proposal['optionalNamespaces']);
    // De-dup.
    return out.map((k, v) => MapEntry(k, v.toSet().toList()));
  }

  String? _accountNamespace(String type) {
    switch (type) {
      case 'ethereum':
        return 'eip155';
      case 'solana':
        return 'solana';
      case 'bitcoin':
        return 'bip122';
    }
    return null;
  }

  Future<void> _handleRequest(WcSessionRequest r) async {
    final url = (r.peerMetadata['url'] as String?) ?? 'walletconnect:';
    try {
      final result = await client.web3.request(
        url: url,
        query: <String, dynamic>{'method': r.method, 'params': r.params},
      );
      await client.walletConnect.respond(r.topic, r.id, result);
    } catch (e) {
      try {
        await client.walletConnect.respondError(
          r.topic,
          r.id,
          message: e.toString(),
        );
      } catch (err) {
        debugPrint('respondError failed: $err');
      }
    }
  }

  @override
  void dispose() {
    _propSub?.cancel();
    _reqSub?.cancel();
    super.dispose();
  }
}

/// One row in the WC approval sheet account picker: the underlying libwallet
/// account, the chain we'd advertise it on, and the CAIP-10 string to send.
class WcCandidateAccount {
  final String accountId;
  final String address;
  final String chainId; // CAIP-2
  final String type; // libwallet account type (ethereum/solana/bitcoin)
  final String namespace; // eip155 / solana / bip122
  final String caip10;

  const WcCandidateAccount({
    required this.accountId,
    required this.address,
    required this.chainId,
    required this.type,
    required this.namespace,
    required this.caip10,
  });
}
