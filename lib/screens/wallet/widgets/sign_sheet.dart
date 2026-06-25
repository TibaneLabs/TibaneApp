import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show SigningKey, Wallet, WalletKey;

import '../../../services/wallet/signing.dart';
import '../../../theme/tibane_theme.dart';
import '../../../widgets/gradient_button.dart';

/// Per-transaction sign sheet (Ellipx-parity Phase 1, §4.3).
///
/// Ported from Ellipx's `DialogWalletKeysUnlock` / `WalletKeysUnlock`, as a
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
Future<List<SigningKey>?> showSignSheet(
  BuildContext context, {
  required Wallet wallet,
  required Future<String?> Function(WalletKey storeKey, String? password)
      readStoreKey,
}) {
  return showModalBottomSheet<List<SigningKey>>(
    context: context,
    backgroundColor: TibaneColors.card,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _SignSheet(wallet: wallet, readStoreKey: readStoreKey),
  );
}

class _SignSheet extends StatefulWidget {
  const _SignSheet({required this.wallet, required this.readStoreKey});

  final Wallet wallet;
  final Future<String?> Function(WalletKey storeKey, String? password)
      readStoreKey;

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

  bool _isUnlocked(WalletKey key) =>
      _collected.any((k) => k.id == key.id);

  Future<void> _unlock(WalletKey key) async {
    if (_busy || _isUnlocked(key) || key.isRemoteKey) return;
    setState(() => _error = null);

    if (key.isPassword) {
      // Reuse the password already typed this sheet, so a D5 wallet's two
      // Password shares only prompt once.
      var pwd = _password;
      if (pwd == null) {
        pwd = await _askPassword();
        if (pwd == null || pwd.isEmpty) return;
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
        final priv = _storeKeyPriv ??
            await widget.readStoreKey(key, _password);
        if (!mounted) return;
        if (priv == null || priv.isEmpty) {
          setState(() => _error =
              'Could not read your device key on this device. Recover it via '
              '2FA in wallet settings, or enter your password first.');
          return;
        }
        setState(() {
          _storeKeyPriv = priv;
          _collected.add(SigningKey(id: key.id, key: priv, type: 'StoreKey'));
        });
      } catch (e) {
        setState(() => _error = 'Device key unlock failed: $e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<String?> _askPassword() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: const Text('Wallet password'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Password'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
            Text(
              'Authorize transaction',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              'Unlock $_required of your wallet keys to sign this transaction.',
              style: const TextStyle(color: TibaneColors.textMuted),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < _wallet.keys.length; i++)
              _keyRow(i, _wallet.keys[i]),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: TibaneColors.error, fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '${_collected.length} / $_required keys unlocked',
              style: const TextStyle(color: TibaneColors.textDim, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed:
                        _busy ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GradientButton(
                    label: 'Sign',
                    onPressed: _ready && !_busy
                        ? () => Navigator.pop(context, _collected)
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _keyRow(int index, WalletKey key) {
    final unlocked = _isUnlocked(key);
    final remote = key.isRemoteKey;
    final loading = _busy && key.isStoreKey && !unlocked;
    final subtitle = remote
        ? 'Recovery only (2FA)'
        : key.isStoreKey
            ? 'This device'
            : 'Password';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: TibaneColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: unlocked ? TibaneColors.cyan : TibaneColors.border,
        ),
      ),
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
        title: Text('Key ${index + 1} — ${key.type}'),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: TibaneColors.textDim, fontSize: 12),
        ),
        trailing: unlocked
            ? const Icon(Icons.check, color: TibaneColors.cyan, size: 18)
            : null,
      ),
    );
  }
}
