import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart';

import '../../screens/browser/approval_sheets.dart';
import '../../screens/wallet/inapp_unlock_screen.dart';
import 'libwallet_backend.dart';

/// Routes pending Web3 requests from the libwallet client to approval sheets,
/// then approves or rejects. Constructed once per browser session and
/// subscribed to `client.pendingRequests`.
class LibwalletRequestBridge {
  final LibwalletClient client;
  final LibwalletBackend backend;
  final BuildContext Function() contextProvider;

  LibwalletRequestBridge({
    required this.client,
    required this.backend,
    required this.contextProvider,
  });

  Future<void> handle(PendingRequest req) async {
    final ctx = contextProvider();
    if (!ctx.mounted) {
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
  }

  Future<void> _handleWatchAsset(
    BuildContext ctx,
    WatchAssetRequest req,
  ) async {
    final ok = await showWatchAssetSheet(ctx, req: req);
    if (!ok) {
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
    if (!ok) {
      await _reject(req.id);
      return;
    }
    await client.requests.approve(req.id, accounts: [accountId]);
  }

  Future<void> _handleTransactionSign(
    BuildContext ctx,
    TransactionSignRequest req,
  ) async {
    if (!await _requireUnlocked(ctx, req.id)) return;
    if (!ctx.mounted) {
      await _reject(req.id);
      return;
    }
    final addr = backend.publicKey;
    final keys = _signingKeys();
    if (addr == null || keys.isEmpty) {
      await _reject(req.id);
      return;
    }
    final host = req.host.isEmpty ? '(unknown)' : req.host;
    // Use the raw base64/hex as payload preview
    final payloadBytes = base64.decode(req.raw.isNotEmpty ? req.raw : '');
    final ok = await showSignSheet(
      ctx,
      host: host,
      verb: req.decodedMethod.isNotEmpty
          ? req.decodedMethod.replaceAll('_', ' ')
          : 'Sign transaction',
      payload: payloadBytes,
      accountAddress: req.from.isNotEmpty ? req.from : addr,
    );
    if (!ok) {
      await _reject(req.id);
      return;
    }
    try {
      await client.requests.approve(req.id, keys: keys);
    } catch (e) {
      debugPrint('approve transaction failed: $e');
      await _reject(req.id);
    }
  }

  Future<void> _handleMessageSign(
    BuildContext ctx,
    MessageSignRequest req,
  ) async {
    if (!await _requireUnlocked(ctx, req.id)) return;
    if (!ctx.mounted) {
      await _reject(req.id);
      return;
    }
    final addr = backend.publicKey;
    final keys = _signingKeys();
    if (addr == null || keys.isEmpty) {
      await _reject(req.id);
      return;
    }
    final ok = await showMessageSignSheet(ctx, req: req, accountAddress: addr);
    if (!ok) {
      await _reject(req.id);
      return;
    }
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
    if (!ok) {
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
    if (result == null) {
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

  /// Just-in-time unlock for handlers that need signing material. The
  /// browser tab itself is ungated — locking the wallet should not
  /// prevent browsing — so the prompt only fires when a destination
  /// actually requests a signature.
  ///
  /// Returns true when the wallet is unlocked and the caller can
  /// proceed; returns false (and rejects the request) when there is
  /// no wallet to sign with, or the user cancelled the unlock.
  Future<bool> _requireUnlocked(BuildContext ctx, String reqId) async {
    if (!backend.hasWallet) {
      await _reject(reqId);
      return false;
    }
    if (backend.isUnlocked) return true;
    if (!ctx.mounted) {
      await _reject(reqId);
      return false;
    }
    final ok = await InAppUnlockScreen.ensureUnlocked(ctx);
    if (!ok || !backend.isUnlocked) {
      await _reject(reqId);
      return false;
    }
    return true;
  }

  List<SigningKey> _signingKeys() {
    return backend.currentSigningKeys
        .map(
          (k) => SigningKey(
            id: k['Id'] as String,
            key: k['Key'] as String,
            type: k['Type'] as String?,
          ),
        )
        .toList();
  }

  Future<void> _reject(String reqId) async {
    try {
      await client.requests.reject(reqId);
    } catch (_) {}
  }
}
