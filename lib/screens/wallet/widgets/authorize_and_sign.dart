import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show SigningKey;
import 'package:provider/provider.dart';

import '../../../services/wallet/signing.dart';
import '../../../services/wallet_service.dart';
import '../inapp_unlock_screen.dart';
import 'sign_sheet.dart';

/// Per-transaction authorize-and-sign helpers (Ellipx-parity Phase 4a, §4.3).
///
/// These centralize the `send_screen` pattern so every in-app sign site can
/// authorize per transaction via the sign sheet. With `kLocklessSigning` on
/// (or for a D5 wallet with no StoreKey), signing collects shares via the sheet
/// and uses the backend's `*WithKeys` methods; otherwise it falls back to the
/// legacy `ensureUnlocked` + cached session. MWA wallets always take the legacy
/// path (Seed Vault does its own auth).
///
/// Phase 4a-1 ships these dormant (the flag defaults off); Phase 4a-2 flips the
/// flag and converts the remaining sign sites to call them.

/// Whether the current sign should authorize per-transaction via the sheet.
/// Only in-app wallets, and only when lockless signing is on OR the wallet has
/// no StoreKey (a D5 committee that can't use the cached path).
bool useSignSheet(WalletService wallet) => useSignSheetFor(
      isInApp: wallet.kind == WalletKind.inapp,
      lockless: kLocklessSigning,
      walletRequiresSheet: wallet.libwallet.requiresSignSheet,
    );

void _toast(BuildContext context, String message) {
  debugPrint('[authorizeAndSign] $message');
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Collect per-transaction signing keys for the current in-app wallet via the
/// sign sheet. Returns the keys, or null when the user cancels or the wallet
/// can't be signed on this device (an explanatory toast is shown). Only call
/// when [useSignSheet] is true.
Future<List<SigningKey>?> collectSigningKeys(BuildContext context) async {
  final lw = context.read<WalletService>().libwallet;
  final wallet = await lw.currentWallet();
  if (!context.mounted) return null;
  if (wallet == null) {
    _toast(context, 'No in-app wallet to sign with.');
    return null;
  }
  if (!canAssembleThreshold(wallet)) {
    _toast(
      context,
      'This wallet can’t be signed on this device. Recover the device key via '
      '2FA in wallet settings.',
    );
    return null;
  }
  return showSignSheet(
    context,
    wallet: wallet,
    readStoreKey: (storeKey, password) =>
        lw.readStoreKeyPrivate(storeKey, password: password),
  );
}

/// Authorize + sign-and-broadcast [txs]. Lockless: collect keys once via the
/// sheet, then `signAndSendTransactionsWithKeys`. Legacy: `ensureUnlocked` +
/// the cached session. Returns the per-tx signatures, or null if cancelled /
/// not authorized.
Future<List<String?>?> authorizeAndSignAndSend(
  BuildContext context,
  List<Uint8List> txs,
) async {
  final wallet = context.read<WalletService>();
  if (useSignSheet(wallet)) {
    final keys = await collectSigningKeys(context);
    if (keys == null || !context.mounted) return null;
    return wallet.libwallet.signAndSendTransactionsWithKeys(txs, keys);
  }
  if (!await InAppUnlockScreen.ensureUnlocked(context)) return null;
  if (!context.mounted) return null;
  return wallet.signAndSendTransactions(txs);
}

/// Authorize + sign-only [txs] (the relayer/co-signer broadcasts). Returns the
/// signed bytes per tx, or null if cancelled / not authorized.
Future<List<Uint8List?>?> authorizeAndSignTransactions(
  BuildContext context,
  List<Uint8List> txs,
) async {
  final wallet = context.read<WalletService>();
  if (useSignSheet(wallet)) {
    final keys = await collectSigningKeys(context);
    if (keys == null || !context.mounted) return null;
    return wallet.libwallet.signTransactionsWithKeys(txs, keys);
  }
  if (!await InAppUnlockScreen.ensureUnlocked(context)) return null;
  if (!context.mounted) return null;
  return wallet.signTransactions(txs);
}

/// Sign + broadcast a single [tx] using a batch authorization obtained ONCE by
/// the caller: [keys] from the sheet (non-null) for the lockless path, or null
/// to use the cached session. For loops/batches that collect/authorize once
/// (e.g. incinerator, swap) so the sheet isn't shown per transaction. No UI —
/// the authorization already happened.
Future<String?> signAndSendOne(
  WalletService wallet,
  Uint8List tx,
  List<SigningKey>? keys,
) async {
  final out = keys != null
      ? await wallet.libwallet.signAndSendTransactionsWithKeys([tx], keys)
      : await wallet.signAndSendTransactions([tx]);
  return out.isEmpty ? null : out.first;
}

/// Sign-only a single [tx] with a batch authorization (the relayer co-signs and
/// broadcasts). See [signAndSendOne].
Future<Uint8List?> signOne(
  WalletService wallet,
  Uint8List tx,
  List<SigningKey>? keys,
) async {
  final out = keys != null
      ? await wallet.libwallet.signTransactionsWithKeys([tx], keys)
      : await wallet.signTransactions([tx]);
  return out.isEmpty ? null : out.first;
}

/// Authorize ONCE for a batch: collect sheet keys (lockless) or `ensureUnlocked`
/// (legacy). Returns a [BatchAuth] whose `.keys` is non-null for the sheet path
/// and null for the legacy/cached path; returns null if the user cancelled or
/// the wallet can't be signed. Pass `.keys` to [signAndSendOne] / [signOne] for
/// each tx in the batch.
Future<BatchAuth?> authorizeBatch(BuildContext context) async {
  final wallet = context.read<WalletService>();
  if (useSignSheet(wallet)) {
    final keys = await collectSigningKeys(context);
    if (keys == null) return null;
    return BatchAuth(keys);
  }
  if (!await InAppUnlockScreen.ensureUnlocked(context)) return null;
  return const BatchAuth(null);
}

/// Result of [authorizeBatch]: the sheet-collected keys (lockless) or null
/// (legacy cached session).
class BatchAuth {
  const BatchAuth(this.keys);
  final List<SigningKey>? keys;
}

/// Authorize + sign [message]. Returns the signature, or null if cancelled /
/// not authorized.
Future<Uint8List?> authorizeAndSignMessage(
  BuildContext context,
  Uint8List message,
) async {
  final wallet = context.read<WalletService>();
  if (useSignSheet(wallet)) {
    final keys = await collectSigningKeys(context);
    if (keys == null || !context.mounted) return null;
    return wallet.libwallet.signMessageWithKeys(message, keys);
  }
  if (!await InAppUnlockScreen.ensureUnlocked(context)) return null;
  if (!context.mounted) return null;
  return wallet.signMessage(message);
}

/// Ensure the atonline **server session** is authenticated for the current
/// account, signing the login ticket via the sheet on demand (Phase 4a, lazy
/// server-login). Call this before a server-backed feature (ClawdWallet,
/// relay, etc.) instead of relying on eager auto-login (which can't pop a sheet
/// on launch). Returns true when authenticated; false if cancelled / no wallet.
Future<bool> ensureServerAuthenticated(BuildContext context) async {
  final wallet = context.read<WalletService>();
  if (wallet.isAuthenticatedForCurrent) return true;
  final login = await wallet.beginServerLogin();
  if (!context.mounted) return false;
  if (login == null) return wallet.isAuthenticatedForCurrent;
  final sig = await authorizeAndSignMessage(
    context,
    Uint8List.fromList(utf8.encode(login.message)),
  );
  if (sig == null || !context.mounted) return false;
  await wallet.completeServerLogin(login.ticket, sig);
  return true;
}
