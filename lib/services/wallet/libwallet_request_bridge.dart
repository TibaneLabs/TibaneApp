import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';

import '../../screens/browser/approval_sheets.dart';
import '../../screens/wallet/widgets/authorize_and_sign.dart';
import '../wallet_service.dart';
import 'libwallet_backend.dart';

/// Routes pending Web3 requests from the libwallet client to approval sheets,
/// then approves or rejects. Constructed once per browser session and
/// subscribed to `client.pendingRequests`.
class LibwalletRequestBridge {
  final LibwalletClient client;
  final LibwalletBackend backend;
  final BuildContext Function() contextProvider;

  /// Called after a dApp transaction is approved + submitted, so the host can
  /// refresh balances + the dashboard token list immediately rather than
  /// waiting on libwallet's background poller. See BALANCE_REFRESH_SPEC.md
  /// (Gap 2). Wire to `WalletService.notifyTxCommitted`.
  final void Function()? onTxCommitted;
  final bool Function(PendingRequest)? requestIsCurrent;
  final Map<String, String> _contexts = {};
  final Map<String, PendingRequest> _requests = {};
  String get _context =>
      '${backend.accountId}:${backend.publicKey}:${backend.currentNetwork?.id}';
  bool _isCurrent(PendingRequest request) =>
      _contexts[request.id] == _context &&
      (requestIsCurrent?.call(request) ?? true);

  LibwalletRequestBridge({
    required this.client,
    required this.backend,
    required this.contextProvider,
    this.onTxCommitted,
    this.requestIsCurrent,
  });

  Future<void> handle(PendingRequest req) async {
    if (_contexts.containsKey(req.id)) return;
    _contexts[req.id] = _context;
    _requests[req.id] = req;
    try {
      final ctx = contextProvider();
      if (!ctx.mounted || !_isCurrent(req)) {
        await _reject(req.id);
        return;
      }
      switch (req) {
        case ConnectRequest():
          await _handleConnect(ctx, req);
        case TransactionSignRequest():
          await _handleTransactionSign(ctx, req);
        case MessageSignRequest():
          await _handleMessageSign(ctx, req);
        case AddNetworkRequest():
          await _handleAddNetwork(ctx, req);
        case ChainSwitchRequest():
          await _handleChainSwitch(ctx, req);
        case WatchAssetRequest():
          await _handleWatchAsset(ctx, req);
        case UnknownPendingRequest():
          await _reject(req.id);
      }
    } catch (error) {
      debugPrint('Web3 request rejected: $error');
      await _reject(req.id);
    } finally {
      _contexts.remove(req.id);
      _requests.remove(req.id);
    }
  }

  Future<void> _handleWatchAsset(
    BuildContext ctx,
    WatchAssetRequest req,
  ) async {
    final ok = await showWatchAssetSheet(ctx, req: req);
    if (!ok || !_isCurrent(req)) {
      await _reject(req.id);
      return;
    }
    await client.requests.approve(req.id);
  }

  Future<void> _handleConnect(BuildContext ctx, ConnectRequest req) async {
    final accountId = backend.accountId;
    final addr = backend.publicKey;
    if (accountId == null || addr == null) {
      await _reject(req.id);
      return;
    }
    final ok = await showConnectSheet(
      ctx,
      host: req.host.isEmpty ? '(unknown)' : req.host,
      accountAddress: addr,
    );
    if (!ok || !_isCurrent(req)) {
      await _reject(req.id);
      return;
    }
    await client.requests.approve(req.id, accounts: [accountId]);
  }

  Future<void> _handleTransactionSign(
    BuildContext ctx,
    TransactionSignRequest req,
  ) async {
    if (!backend.hasWallet) {
      await _reject(req.id);
      return;
    }
    final addr = backend.publicKey;
    if (addr == null) {
      await _reject(req.id);
      return;
    }
    if (req.account != null && req.account != backend.accountId) {
      await _reject(req.id);
      return;
    }
    if (req.from.isNotEmpty &&
        (req.chain == 'evm'
            ? req.from.toLowerCase() != addr.toLowerCase()
            : req.from != addr)) {
      await _reject(req.id);
      return;
    }
    final payloadBytes = decodeTransactionPayload(req.chain, req.raw);
    final ok = await showTransactionSignSheet(
      ctx,
      req: req,
      payload: payloadBytes,
      accountAddress: req.from.isNotEmpty ? req.from : addr,
    );
    if (!ok || !_isCurrent(req)) {
      await _reject(req.id);
      return;
    }
    if (!ctx.mounted) {
      await _reject(req.id);
      return;
    }
    final keys = await _collectApprovalKeys(ctx, req.id);
    if (keys == null) return; // already rejected
    try {
      await client.requests.approve(req.id, keys: keys);
      // The dApp tx is signed + submitted — refresh balances/token list now
      // instead of waiting on the ~60s poller (Gap 2).
      onTxCommitted?.call();
    } catch (e) {
      debugPrint('approve transaction failed: $e');
      await _reject(req.id);
    }
  }

  Future<void> _handleMessageSign(
    BuildContext ctx,
    MessageSignRequest req,
  ) async {
    if (!backend.hasWallet) {
      await _reject(req.id);
      return;
    }
    final addr = backend.publicKey;
    if (addr == null) {
      await _reject(req.id);
      return;
    }
    final ok = await showMessageSignSheet(ctx, req: req, accountAddress: addr);
    if (!ok || !_isCurrent(req)) {
      await _reject(req.id);
      return;
    }
    if (!ctx.mounted) {
      await _reject(req.id);
      return;
    }
    final keys = await _collectApprovalKeys(ctx, req.id);
    if (keys == null) return; // already rejected
    try {
      await client.requests.approve(req.id, keys: keys);
    } catch (e) {
      debugPrint('approve message sign failed: $e');
      await _reject(req.id);
    }
  }

  Future<void> _handleAddNetwork(
    BuildContext ctx,
    AddNetworkRequest req,
  ) async {
    final ok = await showAddNetworkSheet(ctx, req: req);
    if (!ok || !_isCurrent(req)) {
      await _reject(req.id);
      return;
    }
    try {
      await client.requests.approve(req.id);
    } catch (e) {
      debugPrint('approve add network failed: $e');
      await _reject(req.id);
    }
  }

  Future<void> _handleChainSwitch(
    BuildContext ctx,
    ChainSwitchRequest req,
  ) async {
    final result = await showChainSwitchSheet(ctx, req: req);
    if (result == null || !_isCurrent(req)) {
      await _reject(req.id);
      return;
    }
    try {
      await client.requests.approve(
        req.id,
        network: result.networkId,
        accounts: result.accountId != null ? [result.accountId!] : null,
      );
    } catch (e) {
      debugPrint('approve chain switch failed: $e');
      await _reject(req.id);
    }
  }

  /// Collect the signing keys to approve a request, AFTER the dApp approval
  /// preview — per-transaction via the sign sheet. The browser tab itself is
  /// ungated; the sheet only fires when a destination requests a signature.
  /// Rejects [reqId] and returns null on cancel, no wallet, or a current
  /// account that can't sign here (MWA — the web3 bridge is in-app only).
  Future<List<SigningKey>?> _collectApprovalKeys(
    BuildContext ctx,
    String reqId,
  ) async {
    if (!backend.hasWallet || !useSignSheet(ctx.read<WalletService>())) {
      await _reject(reqId);
      return null;
    }
    final collected = await collectSigningKeys(ctx);
    final request = _requests[reqId];
    if (collected == null || request == null || !_isCurrent(request)) {
      await _reject(reqId);
      return null;
    }
    return collected;
  }

  Future<void> _reject(String reqId) async {
    try {
      await client.requests.reject(reqId);
    } catch (_) {}
  }
}

Uint8List decodeTransactionPayload(String chain, String raw) {
  if (raw.length > 512 * 1024) {
    throw const FormatException('Transaction too large');
  }
  if (chain == 'solana') return base64Decode(raw);
  if (chain != 'evm' && chain != 'bitcoin') {
    throw const FormatException('Unsupported transaction chain');
  }
  final hex = raw.startsWith('0x') ? raw.substring(2) : raw;
  if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
    throw const FormatException('Invalid transaction encoding');
  }
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
