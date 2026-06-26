import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../settings_screen.dart' show SettingsTile;
import '../wallet/cloud_backup_screen.dart';
import '../wallet/inapp_unlock_screen.dart';
import '../../utils/log.dart';

/// Sub-screen reached from Settings → "Security & Privacy". Hosts the
/// biometric toggle, password change, TSS share rotations, and cloud
/// backup — all the surface area that affects key custody / auth.
///
/// The biometric / password / rotation options only make sense when the
/// in-app wallet backend is active; they're suppressed when the user is
/// running on MWA / Seed Vault since libwallet doesn't own the keys.
class SecurityPrivacyScreen extends StatelessWidget {
  const SecurityPrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    final inapp = wallet.kind == WalletKind.inapp;
    final hasInappWallet = inapp && wallet.libwallet.hasWallet;

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Security & Privacy')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              if (hasInappWallet) ...[
                SettingsTile(
                  icon: Icons.password_outlined,
                  title: 'Change password',
                  subtitle: 'Reshare the Password share with a new secret',
                  onTap: () => _changePassword(context, wallet),
                ),
                const SizedBox(height: 6),
                SettingsTile(
                  icon: Icons.refresh,
                  title: 'Rotate device share',
                  subtitle: 'Replace the on-device TSS share with a fresh one',
                  onTap: () => _rotateDeviceShare(context, wallet),
                ),
                const SizedBox(height: 6),
                SettingsTile(
                  icon: Icons.sms_outlined,
                  title: 'Rotate 2FA share',
                  subtitle: 'Reshare the remote (email / SMS) TSS share',
                  onTap: () => _rotateRemoteKey(context, wallet),
                ),
                const SizedBox(height: 6),
                SettingsTile(
                  icon: Icons.healing_outlined,
                  title: 'Recover device key (2FA)',
                  subtitle:
                      "Re-mint this device's TSS share via 2FA — use if signing "
                      "can't find the device key (e.g. on a new device)",
                  onTap: () => _recoverDeviceShare(context, wallet),
                ),
              ] else ...[
                TibaneCard(
                  padding: const EdgeInsets.all(16),
                  child: const Text(
                    'Security options are managed by your external wallet. '
                    'Switch to or create an in-app wallet to see password, '
                    'biometric, and TSS share controls here.',
                    style: TextStyle(color: TibaneColors.textMuted),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              // Cloud backup stays reachable even with no in-app wallet: it's
              // the only restore path, and restore requires NO wallet loaded —
              // so it can't live behind the has-in-app-wallet gate. The screen
              // self-gates its actions (back-up needs an unlocked wallet,
              // restore needs none).
              SettingsTile(
                icon: Icons.cloud_outlined,
                title: 'Cloud backup',
                subtitle: 'Auto-backup via iCloud Backup / Google Auto Backup',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CloudBackupScreen()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _changePassword(
    BuildContext context,
    WalletService wallet,
  ) async {
    final result = await showDialog<_PasswordChange>(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );
    if (result == null) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await wallet.libwallet.changePassword(
      oldPassword: result.oldPassword,
      newPassword: result.newPassword,
    );
    if (!context.mounted) return;
    if (!ok) {
      logError('[SecurityPrivacy._changePassword] failed: ${wallet.libwallet.error}');
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Password changed'
              : (wallet.libwallet.error ?? 'Change password failed'),
        ),
      ),
    );
  }

  Future<void> _rotateRemoteKey(
    BuildContext context,
    WalletService wallet,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: const Text('Rotate 2FA share?'),
        content: const Text(
          'This sends a fresh verification code to the email or phone tied '
          'to this wallet and reshares the remote TSS key. Use it if you '
          'suspect the 2FA channel has been compromised.',
          style: TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Start',
              style: TextStyle(color: TibaneColors.orange),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final session = await wallet.libwallet.startRemoteKeyReshare();
    if (session == null) {
      logError('[SecurityPrivacy._rotateRemoteKey] reshare start failed: ${wallet.libwallet.error}');
      messenger.showSnackBar(
        SnackBar(
          content: Text(wallet.libwallet.error ?? 'Reshare start failed'),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    final code = await showDialog<String>(
      context: context,
      builder: (_) => _CodeEntryDialog(length: session.length),
    );
    if (code == null || code.isEmpty) return;
    final ok = await wallet.libwallet.completeRemoteKeyReshare(
      session: session.session,
      code: code,
    );
    if (!context.mounted) return;
    if (!ok) {
      logError('[SecurityPrivacy._rotateRemoteKey] reshare failed: ${wallet.libwallet.error}');
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '2FA share rotated'
              : (wallet.libwallet.error ?? 'Reshare failed'),
        ),
      ),
    );
  }

  /// Explicit 2FA device-share recovery (Ellipx-parity §4.8). Routes to the
  /// unlock screen's recovery mode, which re-mints this device's StoreKey share
  /// via 2FA. Reachable when signing can't read the device key (cross-device).
  Future<void> _recoverDeviceShare(
    BuildContext context,
    WalletService wallet,
  ) async {
    final walletId = wallet.libwallet.walletId;
    if (walletId == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InAppUnlockScreen(
          walletId: walletId,
          forceRecovery: true,
        ),
      ),
    );
  }

  Future<void> _rotateDeviceShare(
    BuildContext context,
    WalletService wallet,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: const Text('Rotate device share?'),
        content: const Text(
          'This invalidates the TSS share stored on this device and replaces '
          'it with a fresh one. Use it if you suspect the device has been '
          'compromised.',
          style: TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Rotate',
              style: TextStyle(color: TibaneColors.orange),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    if (!await InAppUnlockScreen.ensureUnlocked(context)) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await wallet.libwallet.rotateDeviceShare();
    if (!context.mounted) return;
    if (!ok) {
      logError('[SecurityPrivacy._rotateDeviceShare] rotate failed: ${wallet.libwallet.error}');
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Device share rotated'
              : (wallet.libwallet.error ?? 'Rotate failed'),
        ),
      ),
    );
  }
}

class _PasswordChange {
  final String oldPassword;
  final String newPassword;

  const _PasswordChange(this.oldPassword, this.newPassword);
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _oldCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _oldCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final oldPw = _oldCtrl.text;
    final newPw = _newCtrl.text;
    final confirm = _confirmCtrl.text;
    if (oldPw.isEmpty) {
      logError('[SecurityPrivacy._ChangePasswordDialog] validation error: current password empty');
      setState(() => _error = 'Enter the current password');
      return;
    }
    if (newPw.length < 8) {
      logError('[SecurityPrivacy._ChangePasswordDialog] validation error: new password too short');
      setState(() => _error = 'New password must be at least 8 characters');
      return;
    }
    if (newPw != confirm) {
      logError('[SecurityPrivacy._ChangePasswordDialog] validation error: new passwords do not match');
      setState(() => _error = 'New passwords do not match');
      return;
    }
    Navigator.of(context).pop(_PasswordChange(oldPw, newPw));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      title: const Text('Change password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _oldCtrl,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Current password'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newCtrl,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'New password'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Confirm new password',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: TibaneColors.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text(
            'Change',
            style: TextStyle(color: TibaneColors.orange),
          ),
        ),
      ],
    );
  }
}

class _CodeEntryDialog extends StatefulWidget {
  final int length;

  const _CodeEntryDialog({required this.length});

  @override
  State<_CodeEntryDialog> createState() => _CodeEntryDialogState();
}

class _CodeEntryDialogState extends State<_CodeEntryDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      title: const Text('Enter verification code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Check your email or SMS for the ${widget.length}-digit code.',
            style: const TextStyle(color: TibaneColors.textMuted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(widget.length),
            ],
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Code'),
            style: monoStyle(fontSize: 18),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: const Text(
            'Verify',
            style: TextStyle(color: TibaneColors.orange),
          ),
        ),
      ],
    );
  }
}
