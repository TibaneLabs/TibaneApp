import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../settings_screen.dart' show SettingsTile;
import '../wallet/cloud_backup_screen.dart';
import '../wallet/inapp_unlock_screen.dart';
import '../wallet/widgets/authorize_and_sign.dart' show collectManagementKeys;
import '../../utils/log.dart';
import '../../widgets/wallet_error_display.dart';
import '../../utils/context_extensions.dart';

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
    final l10n = context.l10n;
    final wallet = context.watch<WalletService>();
    final inapp = wallet.kind == WalletKind.inapp;
    final hasInappWallet = inapp && wallet.libwallet.hasWallet;

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.settingsSecurityPrivacyTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              if (hasInappWallet) ...[
                SettingsTile(
                  icon: Icons.password_outlined,
                  title: l10n.securityChangePasswordTitle,
                  subtitle: l10n.securityChangePasswordSubtitle,
                  onTap: () => _changePassword(context, wallet),
                ),
                const SizedBox(height: 6),
                SettingsTile(
                  icon: Icons.refresh,
                  title: l10n.securityResetDeviceKeyTitle,
                  subtitle: l10n.securityResetDeviceKeySubtitle,
                  onTap: () => _rotateDeviceShare(context, wallet),
                ),
                const SizedBox(height: 6),
                SettingsTile(
                  icon: Icons.sms_outlined,
                  title: l10n.securityReset2faTitle,
                  subtitle: l10n.securityReset2faSubtitle,
                  onTap: () => _rotateRemoteKey(context, wallet),
                ),
                const SizedBox(height: 6),
                SettingsTile(
                  icon: Icons.healing_outlined,
                  title: l10n.securitySetUpSigningTitle,
                  subtitle: l10n.securitySetUpSigningSubtitle,
                  onTap: () => _recoverDeviceShare(context, wallet),
                ),
              ] else ...[
                TibaneCard(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    l10n.securityExternalWalletNotice,
                    style: const TextStyle(color: TibaneColors.textMuted),
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
                title: l10n.securityCloudBackupTitle,
                subtitle: l10n.securityCloudBackupSubtitle,
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

  /// Run a slow key-management op behind a non-dismissible progress dialog, so
  /// tapping "OK" gives immediate feedback instead of a silently-closed modal
  /// (the reshare is a networked TSS ceremony that can take several seconds).
  /// The dialog is torn down when [op] settles, whatever the outcome.
  Future<T> _withProgress<T>(
    BuildContext context,
    String message,
    Future<T> Function() op,
  ) async {
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: TibaneColors.card,
          content: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: TibaneColors.orange,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(color: TibaneColors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    try {
      return await op();
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
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
    final l10n = context.l10n;
    final messenger = context.messenger;
    // A reshare re-splits the wallet secret, so the RemoteKey share must be
    // re-pushed under a fresh, active session — minting it sends a 2FA code.
    final session = await _withProgress(
      context,
      l10n.securitySendingCode,
      () => wallet.libwallet.startRemoteKeyReshare(),
    );
    if (!context.mounted) return;
    if (session == null) {
      logError('[SecurityPrivacy._changePassword] reshare start failed: ${wallet.libwallet.error}');
      showWalletError(context, wallet.libwallet.error ?? 'Could not send code');
      return;
    }
    final code = await showDialog<String>(
      context: context,
      builder: (_) => _CodeEntryDialog(length: session.length),
    );
    if (code == null || code.isEmpty) return;
    if (!context.mounted) return;
    final ok = await _withProgress(
      context,
      l10n.securityChangingPassword,
      () => wallet.libwallet.changePassword(
        sessionToken: session.session,
        code: code,
        oldPassword: result.oldPassword,
        newPassword: result.newPassword,
      ),
    );
    if (!context.mounted) return;
    if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.securityPasswordChanged)),
      );
    } else {
      logError('[SecurityPrivacy._changePassword] failed: ${wallet.libwallet.error}');
      showWalletError(context, wallet.libwallet.error ?? 'Change password failed');
    }
  }

  Future<void> _rotateRemoteKey(
    BuildContext context,
    WalletService wallet,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(l10n.securityRotate2faDialogTitle),
        content: Text(
          l10n.securityRotate2faDialogBody,
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.securityRotate2faStart,
              style: const TextStyle(color: TibaneColors.orange),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    final messenger = context.messenger;
    final session = await wallet.libwallet.startRemoteKeyReshare();
    if (session == null) {
      logError('[SecurityPrivacy._rotateRemoteKey] reshare start failed: ${wallet.libwallet.error}');
      if (!context.mounted) return;
      showWalletError(context, wallet.libwallet.error ?? 'Reshare start failed');
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
    if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.security2faShareRotated)),
      );
    } else {
      logError('[SecurityPrivacy._rotateRemoteKey] reshare failed: ${wallet.libwallet.error}');
      showWalletError(context, wallet.libwallet.error ?? 'Reshare failed');
    }
  }

  /// Explicit 2FA device-share recovery (Atonline-parity §4.8). Routes to the
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
        builder: (_) => InAppUnlockScreen(walletId: walletId),
      ),
    );
  }

  Future<void> _rotateDeviceShare(
    BuildContext context,
    WalletService wallet,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(l10n.securityRotateDeviceDialogTitle),
        content: Text(
          l10n.securityRotateDeviceDialogBody,
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.securityRotateDeviceAction,
              style: const TextStyle(color: TibaneColors.orange),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    // 6D: collect the wallet credentials (biometric StoreKey + password) via the
    // management-auth sheet instead of the legacy full-screen unlock.
    final creds = await collectManagementKeys(
      context,
      title: 'Rotate device share',
      purpose: "rotate this device's key share",
    );
    if (creds == null || !context.mounted) return;
    final messenger = context.messenger;
    // Rotation is a reshare → needs a fresh RemoteKey session (2FA code).
    final session = await _withProgress(
      context,
      l10n.securitySendingCode,
      () => wallet.libwallet.startRemoteKeyReshare(),
    );
    if (!context.mounted) return;
    if (session == null) {
      logError('[SecurityPrivacy._rotateDeviceShare] reshare start failed: ${wallet.libwallet.error}');
      showWalletError(context, wallet.libwallet.error ?? 'Could not send code');
      return;
    }
    final code = await showDialog<String>(
      context: context,
      builder: (_) => _CodeEntryDialog(length: session.length),
    );
    if (code == null || code.isEmpty) return;
    if (!context.mounted) return;
    final ok = await _withProgress(
      context,
      l10n.securityRotatingDeviceShare,
      () => wallet.libwallet.rotateDeviceShare(
        sessionToken: session.session,
        code: code,
        password: creds.password,
        storeKeyPriv: creds.storeKeyPriv,
      ),
    );
    if (!context.mounted) return;
    if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.securityDeviceShareRotated)),
      );
    } else {
      logError('[SecurityPrivacy._rotateDeviceShare] rotate failed: ${wallet.libwallet.error}');
      showWalletError(context, wallet.libwallet.error ?? 'Rotate failed');
    }
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
    final l10n = context.l10n;
    final oldPw = _oldCtrl.text;
    final newPw = _newCtrl.text;
    final confirm = _confirmCtrl.text;
    if (oldPw.isEmpty) {
      logError('[SecurityPrivacy._ChangePasswordDialog] validation error: current password empty');
      setState(() => _error = l10n.securityPwEnterCurrent);
      return;
    }
    if (newPw.length < 8) {
      logError('[SecurityPrivacy._ChangePasswordDialog] validation error: new password too short');
      setState(() => _error = l10n.securityPwTooShort);
      return;
    }
    if (newPw != confirm) {
      logError('[SecurityPrivacy._ChangePasswordDialog] validation error: new passwords do not match');
      setState(() => _error = l10n.securityPwNoMatch);
      return;
    }
    Navigator.of(context).pop(_PasswordChange(oldPw, newPw));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      title: Text(l10n.securityChangePasswordTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _oldCtrl,
            obscureText: true,
            decoration: InputDecoration(labelText: l10n.securityPwCurrentLabel),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newCtrl,
            obscureText: true,
            decoration: InputDecoration(labelText: l10n.securityPwNewLabel),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.securityPwConfirmLabel,
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
          child: Text(l10n.actionCancel),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(
            l10n.securityPwChangeAction,
            style: const TextStyle(color: TibaneColors.orange),
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
    final l10n = context.l10n;
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      title: Text(l10n.securityCodeEntryTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.securityCodeEntryBody(widget.length),
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
            decoration: InputDecoration(labelText: l10n.securityCodeLabel),
            style: monoStyle(fontSize: 18),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.actionCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: Text(
            l10n.securityCodeVerify,
            style: const TextStyle(color: TibaneColors.orange),
          ),
        ),
      ],
    );
  }
}
