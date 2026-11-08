import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show SigningKey, Wallet, WalletKey;

import '../../../l10n/l10n.dart';
import '../../../services/wallet/signing.dart';
import '../../../services/wallet/wallet_export_format.dart'
    show isNormalMnemonicWallet;
import '../../../theme/tibane_theme.dart';
import '../../../utils/wallet_error.dart';
import '../../../widgets/gradient_button.dart';
import '../../../utils/context_extensions.dart';
import 'wallet_password_dialog.dart';

/// Per-transaction sign sheet (Atonline-parity Phase 1, §4.3).
///
/// Ported from Atonline's `DialogWalletKeysUnlock` / `WalletKeysUnlock`, as a
/// Tibane modal bottom sheet with inline English strings (D15). It collects
/// `threshold + 1` key shares for ONE signature and returns them; nothing is
/// cached beyond this sheet instance (no app-level unlock).
///
/// One tappable row per `wallet.keys`:
///  * **Password** → prompt, kept as `SigningKey(id, typedPassword, 'Password')`.
///  * **StoreKey** → resolved via [readStoreKey] (the §3.2 fallback chain:
///    biometric_storage → no-auth keystore → password blob).
///  * **RemoteKey** → disabled (recovery-only / dormant, D9).
///
/// Returns the collected `List<SigningKey>` on confirm, or `null` on cancel /
/// dismiss. [readStoreKey] receives the StoreKey [WalletKey] and the password
/// already typed in this sheet (if any, for the blob fallback step).
/// Ordinary mnemonic wallets request only their password, without a share sheet.
Future<List<SigningKey>?> showSignSheet(
  BuildContext context, {
  required Wallet wallet,
  required Future<String?> Function(WalletKey storeKey, String? password)
  readStoreKey,
  String title = 'Authorize transaction',
  String?
  subtitlePurpose, // e.g. 'sign this transaction' (default) / 'change your password'
  String actionLabel = 'Sign',
  bool transactionReviewed = false,
}) async {
  if (transactionReviewed && isSingleDeviceKeyWallet(wallet)) {
    try {
      final key = wallet.keys.single;
      final secret = await readStoreKey(key, null);
      if (!context.mounted) return null;
      if (secret == null || secret.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.signSheetDeviceKeyError),
            duration: const Duration(seconds: 3),
          ),
        );
        return null;
      }
      return [SigningKey(id: key.id, key: secret, type: 'StoreKey')];
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(walletErrorMessageForContext(context, error)),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return null;
    }
  }
  if (isNormalMnemonicWallet(wallet)) {
    final password = await showWalletPasswordDialog(context);
    if (!context.mounted || password == null || password.isEmpty) return null;
    return [
      SigningKey(id: wallet.keys.single.id, key: password, type: 'Password'),
    ];
  }
  return showModalBottomSheet<List<SigningKey>>(
    context: context,
    backgroundColor: TibaneColors.card,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _SignSheet(
      wallet: wallet,
      readStoreKey: readStoreKey,
      title: title,
      subtitlePurpose: subtitlePurpose ?? 'sign this transaction',
      actionLabel: actionLabel,
    ),
  );
}

class _SignSheet extends StatefulWidget {
  const _SignSheet({
    required this.wallet,
    required this.readStoreKey,
    required this.title,
    required this.subtitlePurpose,
    required this.actionLabel,
  });

  final Wallet wallet;
  final Future<String?> Function(WalletKey storeKey, String? password)
  readStoreKey;
  final String title;
  final String subtitlePurpose;
  final String actionLabel;

  @override
  State<_SignSheet> createState() => _SignSheetState();
}

class _SignSheetState extends State<_SignSheet> {
  final List<SigningKey> _collected = [];
  String? _password; // typed once, reused for the StoreKey blob fallback
  String? _storeKeyPriv; // cached so a re-tap doesn't re-prompt biometric
  bool _busy = false;
  String? _error;

  Wallet get _wallet => widget.wallet;
  int get _required => requiredSigningShares(_wallet.threshold);
  bool get _ready => signSheetReady(_collected.length, _wallet.threshold);

  bool _isUnlocked(WalletKey key) => _collected.any((k) => k.id == key.id);

  Future<void> _unlock(WalletKey key) async {
    if (_busy || _isUnlocked(key) || key.isRemoteKey) return;
    setState(() => _error = null);

    if (key.isPassword) {
      // Reuse the password already typed this sheet, so a D5 wallet's two
      // Password shares only prompt once.
      var pwd = _password;
      if (pwd == null) {
        pwd = await showWalletPasswordDialog(context);
        if (!mounted || pwd == null || pwd.isEmpty) return;
      }
      final entered = pwd;
      setState(() {
        _password = entered;
        _collected.add(SigningKey(id: key.id, key: entered, type: 'Password'));
      });
      return;
    }

    if (key.isStoreKey) {
      setState(() => _busy = true);
      try {
        final priv = _storeKeyPriv ?? await widget.readStoreKey(key, _password);
        if (!mounted) return;
        if (priv == null || priv.isEmpty) {
          debugPrint(
            '[signSheet] StoreKey ${key.id} unreadable on this device '
            '(biometric/keystore/blob all empty)',
          );
          setState(() => _error = context.l10n.signSheetDeviceKeyError);
          return;
        }
        setState(() {
          _storeKeyPriv = priv;
          _collected.add(SigningKey(id: key.id, key: priv, type: 'StoreKey'));
        });
      } catch (e) {
        debugPrint('[signSheet] device key unlock failed: $e');
        setState(() => _error = walletErrorMessageForContext(context, e));
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: TibaneColors.textDim,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(widget.title, style: context.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              l10n.signSheetUnlockHint(
                _required.toString(),
                widget.subtitlePurpose,
              ),
              style: const TextStyle(color: TibaneColors.textMuted),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < _wallet.keys.length; i++)
              _keyRow(i, _wallet.keys[i], l10n),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: TibaneColors.error, fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              l10n.signSheetKeysUnlocked(
                _collected.length.toString(),
                _required.toString(),
              ),
              style: const TextStyle(color: TibaneColors.textDim, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GradientButton(
                  label: widget.actionLabel,
                  expanded: true,
                  onPressed: _ready && !_busy
                      ? () => Navigator.pop(context, _collected)
                      : null,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: Text(l10n.actionCancel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _keyRow(int index, WalletKey key, AppLocalizations l10n) {
    final unlocked = _isUnlocked(key);
    final remote = key.isRemoteKey;
    final loading = _busy && key.isStoreKey && !unlocked;
    final subtitle = remote
        ? l10n.signSheetKeyRemote
        : key.isStoreKey
        ? l10n.signSheetKeyDevice
        : l10n.labelPassword;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: TibaneColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: unlocked ? TibaneColors.cyan : TibaneColors.border,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: ListTile(
          onTap: (unlocked || remote || _busy) ? null : () => _unlock(key),
          leading: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  unlocked
                      ? Icons.lock_open
                      : remote
                      ? Icons.lock_outline
                      : Icons.lock,
                  color: unlocked
                      ? TibaneColors.cyan
                      : remote
                      ? TibaneColors.textDim
                      : TibaneColors.textMuted,
                ),
          title: Text(l10n.signSheetKeyTitle((index + 1).toString(), key.type)),
          subtitle: Text(
            subtitle,
            style: const TextStyle(color: TibaneColors.textDim, fontSize: 12),
          ),
          trailing: unlocked
              ? const Icon(Icons.check, color: TibaneColors.cyan, size: 18)
              : null,
        ),
      ),
    );
  }
}
