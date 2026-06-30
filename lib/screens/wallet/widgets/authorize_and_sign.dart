import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show SigningKey;
import 'package:provider/provider.dart';

import '../../../services/wallet/signing.dart';
import '../../../services/wallet_service.dart';
import 'sign_sheet.dart';

/// Per-transaction authorize-and-sign helpers (Atonline-parity §4.3).
///
/// These centralize the sign pattern so every in-app sign site authorizes per
/// transaction via the sign sheet (collect shares → the backend's `*WithKeys`
/// methods). MWA wallets sign through Seed Vault's own auth — the façade routes
/// to the MWA backend directly, no app sheet.

/// Whether the current sign authorizes per-transaction via the sheet: every
/// in-app wallet does. MWA signs via Seed Vault (no sheet).
bool useSignSheet(WalletService wallet) =>
    useSignSheetFor(isInApp: wallet.kind == WalletKind.inapp);

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

/// Authorize + sign-and-broadcast [txs]. In-app: collect keys once via the
/// sheet, then `signAndSendTransactionsWithKeys`. MWA: route to the backend
/// (Seed Vault auth). Returns the per-tx signatures, or null if cancelled.
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
  return wallet.signAndSendTransactions(txs);
}

/// Authorize + sign-only [txs] (the relayer/co-signer broadcasts). Returns the
/// signed bytes per tx, or null if cancelled.
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

/// Authorize ONCE for a batch: collect sheet keys (in-app). Returns a
/// [BatchAuth] whose `.keys` is non-null for the sheet path and null for the
/// MWA path; returns null if the user cancelled or the wallet can't be signed.
/// Pass `.keys` to [signAndSendOne] / [signOne] for each tx in the batch.
Future<BatchAuth?> authorizeBatch(BuildContext context) async {
  final wallet = context.read<WalletService>();
  if (useSignSheet(wallet)) {
    final keys = await collectSigningKeys(context);
    if (keys == null) return null;
    return BatchAuth(keys);
  }
  return const BatchAuth(null);
}

/// Result of [authorizeBatch]: the sheet-collected keys (in-app), or null for
/// the MWA path (Seed Vault signs each tx itself).
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
