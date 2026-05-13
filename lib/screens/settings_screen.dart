import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/wallet/libwallet_backend.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/tibane_card.dart';
import 'about_screen.dart';
import 'clawdwallet/agents_screen.dart';
import 'contacts/contacts_screen.dart';
import 'wallet/accounts_management_screen.dart';
import 'wallet/cloud_backup_screen.dart';
import 'wallet/inapp_export_screen.dart';
import 'wallet/inapp_import_screen.dart';
import 'wallet/inapp_unlock_screen.dart';
import 'wallet/networks_screen.dart';
import 'wallet/wallet_details_screen.dart';
import 'wallet/wallets_management_screen.dart';
import 'walletconnect/walletconnect_sessions_screen.dart';

/// Replaces the legacy "About" tab. Surfaces wallet/account management and
/// keeps the original About content available as a route push so we don't
/// lose anything while migrating.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel('Active account'),
          const SizedBox(height: 10),
          _ActiveWalletCard(wallet: wallet),
          const SizedBox(height: 20),
          _SectionLabel('Manage'),
          const SizedBox(height: 10),
          _SettingsTile(
            icon: Icons.account_circle_outlined,
            title: 'Manage accounts',
            subtitle: 'Chain accounts derived from your wallets',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AccountsManagementScreen(),
              ),
            ),
          ),
          const SizedBox(height: 6),
          _SettingsTile(
            icon: Icons.shield_outlined,
            title: 'Manage wallets',
            subtitle: 'Create, back up, or remove on-device wallets',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const WalletsManagementScreen(),
              ),
            ),
          ),
          const SizedBox(height: 6),
          _SettingsTile(
            icon: Icons.people_outline,
            title: 'Manage contacts',
            subtitle: 'Saved addresses for sends and swaps',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ContactsScreen()),
            ),
          ),
          const SizedBox(height: 6),
          _SettingsTile(
            icon: Icons.hub_outlined,
            title: 'Networks',
            subtitle: 'Pick the active blockchain network',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NetworksScreen()),
            ),
          ),
          const SizedBox(height: 6),
          _SettingsTile(
            icon: Icons.link,
            title: 'WalletConnect',
            subtitle: 'Pair and manage dApp sessions',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const WalletConnectSessionsScreen(),
              ),
            ),
          ),
          const SizedBox(height: 20),
          _SectionLabel('Wallet actions'),
          const SizedBox(height: 10),
          _WalletActions(wallet: wallet),
          const SizedBox(height: 20),
          _SectionLabel('Agent wallets'),
          const SizedBox(height: 10),
          _SettingsTile(
            icon: Icons.precision_manufacturing_outlined,
            title: 'ClawdWallet agents',
            subtitle: 'Provision and manage agent-controlled MPC wallets',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: TibaneColors.black,
                  appBar: AppBar(title: const Text('Agent wallets')),
                  body: const SafeArea(child: AgentsScreen()),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          _SectionLabel('App'),
          const SizedBox(height: 10),
          _SettingsTile(
            icon: Icons.info_outline,
            title: 'About Tibane',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: TibaneColors.black,
                  appBar: AppBar(title: const Text('About')),
                  body: const SafeArea(child: AboutScreen()),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
    );
  }
}

class _ActiveWalletCard extends StatelessWidget {
  final WalletService wallet;
  const _ActiveWalletCard({required this.wallet});

  @override
  Widget build(BuildContext context) {
    if (!wallet.isConnected) {
      return TibaneCard(
        child: Row(
          children: [
            const Icon(Icons.lock_outline, color: TibaneColors.textMuted),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'No wallet connected',
                style: TextStyle(color: TibaneColors.textMuted),
              ),
            ),
          ],
        ),
      );
    }

    final kindLabel = wallet.kind == WalletKind.inapp ? 'In-app' : 'External';
    final address = wallet.publicKey ?? '';
    final shortAddress = address.length > 14
        ? '${address.substring(0, 6)}...${address.substring(address.length - 6)}'
        : address;

    return TibaneCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const WalletDetailsScreen()),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: TibaneColors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  wallet.kind == WalletKind.inapp
                      ? Icons.shield_outlined
                      : Icons.account_balance_wallet_outlined,
                  color: TibaneColors.orange,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      wallet.walletName ?? 'Wallet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      kindLabel,
                      style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'SOLANA ADDRESS',
            style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  shortAddress,
                  style: monoStyle(fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: address));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Address copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WalletActions extends StatelessWidget {
  final WalletService wallet;
  const _WalletActions({required this.wallet});

  @override
  Widget build(BuildContext context) {
    final inapp = wallet.kind == WalletKind.inapp;
    return Column(
      children: [
        if (inapp && wallet.libwallet.hasWallet) ...[
          _BiometricToggleTile(libwallet: wallet.libwallet),
          const SizedBox(height: 6),
          _SettingsTile(
            icon: Icons.password_outlined,
            title: 'Change password',
            subtitle: 'Reshare the Password share with a new secret',
            onTap: () => _changePassword(context),
          ),
          const SizedBox(height: 6),
          _SettingsTile(
            icon: Icons.refresh,
            title: 'Rotate device share',
            subtitle: 'Replace the on-device TSS share with a fresh one',
            onTap: () => _rotateDeviceShare(context),
          ),
          const SizedBox(height: 6),
          _SettingsTile(
            icon: Icons.download_outlined,
            title: 'Export in-app wallet',
            subtitle: 'Encrypted backup file (share or save to disk)',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const InAppExportScreen()),
            ),
          ),
          const SizedBox(height: 6),
          _SettingsTile(
            icon: Icons.cloud_outlined,
            title: 'Cloud backup',
            subtitle: 'Auto-backup via iCloud Backup / Google Auto Backup',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CloudBackupScreen()),
            ),
          ),
          const SizedBox(height: 6),
        ],
        _SettingsTile(
          icon: Icons.upload_outlined,
          title: 'Import wallet',
          subtitle: 'Restore from an encrypted backup file',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const InAppImportScreen()),
          ),
        ),
        if (wallet.isConnected) ...[
          const SizedBox(height: 6),
          _SettingsTile(
            icon: Icons.logout_outlined,
            title: inapp ? 'Lock wallet' : 'Disconnect',
            destructive: true,
            onTap: () => _confirmDisconnect(context),
          ),
        ],
      ],
    );
  }

  Future<void> _confirmDisconnect(BuildContext context) async {
    final inapp = wallet.kind == WalletKind.inapp;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(inapp ? 'Lock wallet?' : 'Disconnect wallet?'),
        content: Text(
          inapp
              ? 'You will need to re-enter your password to unlock the wallet again.'
              : 'You can reconnect by tapping the wallet button at the top.',
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              inapp ? 'Lock' : 'Disconnect',
              style: const TextStyle(color: TibaneColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await wallet.disconnect();
  }

  Future<void> _changePassword(BuildContext context) async {
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
    messenger.showSnackBar(SnackBar(
      content: Text(
        ok
            ? 'Password changed'
            : (wallet.libwallet.error ?? 'Change password failed'),
      ),
    ));
  }

  Future<void> _rotateDeviceShare(BuildContext context) async {
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
    messenger.showSnackBar(SnackBar(
      content: Text(
        ok
            ? 'Device share rotated'
            : (wallet.libwallet.error ?? 'Rotate failed'),
      ),
    ));
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
      setState(() => _error = 'Enter the current password');
      return;
    }
    if (newPw.length < 8) {
      setState(() => _error = 'New password must be at least 8 characters');
      return;
    }
    if (newPw != confirm) {
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
            decoration: const InputDecoration(labelText: 'Confirm new password'),
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

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool destructive;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? TibaneColors.error : TibaneColors.text;
    return TibaneCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: TextStyle(color: color, fontSize: 15)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right,
              color: TibaneColors.textDim, size: 18),
        ],
      ),
    );
  }
}

/// List of libwallet wallets present on this device. Today the app only
/// loads one into memory at a time (`LibwalletBackend.walletId`) and that
/// row is marked "Active"; the rest are read-only entries for now.
/// wiped and signing falls back to the typed password.
class _BiometricToggleTile extends StatefulWidget {
  final LibwalletBackend libwallet;
  const _BiometricToggleTile({required this.libwallet});

  @override
  State<_BiometricToggleTile> createState() => _BiometricToggleTileState();
}

class _BiometricToggleTileState extends State<_BiometricToggleTile> {
  bool? _enabled;
  bool _supported = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await widget.libwallet.isBiometricEnabled();
    final supported = await widget.libwallet.isBiometricSupported();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _supported = supported;
    });
  }

  Future<void> _toggle(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (on) {
        // Need an unlocked wallet (a known password) to cache. If the
        // wallet is locked, route through ensureUnlocked first.
        final wallet = context.read<WalletService>();
        if (!wallet.libwallet.isUnlocked) {
          final ok = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => const _PasswordCachePrompt(),
            ),
          );
          if (ok != true || !mounted) return;
        }
        // Pull the password we just collected from the in-memory cache.
        // It lives on the backend until lock() is called.
        final pw = wallet.libwallet.currentPassword;
        if (pw == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not read password — try unlocking first.'),
          ));
          return;
        }
        final ok = await widget.libwallet.enableBiometricUnlock(pw);
        if (!mounted) return;
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Biometric setup failed — your device may not support it.'),
          ));
          return;
        }
        setState(() => _enabled = true);
      } else {
        await widget.libwallet.disableBiometricUnlock();
        if (!mounted) return;
        setState(() => _enabled = false);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported || _enabled == null) {
      return const SizedBox.shrink();
    }
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.fingerprint, color: TibaneColors.text, size: 20),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Use FaceID / fingerprint to unlock",
                  style: TextStyle(color: TibaneColors.text, fontSize: 15),
                ),
                SizedBox(height: 2),
                Text(
                  "Skip the password screen on each signing action.",
                  style: TextStyle(color: TibaneColors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          Switch(
            value: _enabled!,
            onChanged: _busy ? null : _toggle,
            activeThumbColor: TibaneColors.orange,
          ),
        ],
      ),
    );
  }
}

/// Modal that asks the user for their password so we can stash it behind
/// biometrics. Pops `true` when the password successfully unlocks.
class _PasswordCachePrompt extends StatefulWidget {
  const _PasswordCachePrompt();

  @override
  State<_PasswordCachePrompt> createState() => _PasswordCachePromptState();
}

class _PasswordCachePromptState extends State<_PasswordCachePrompt> {
  final _pwCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final wallet = context.read<WalletService>();
    final ok = await wallet.libwallet.unlock(_pwCtrl.text);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = "Wrong password";
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text("Confirm password")),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                "Enter your wallet password so we can cache it behind your devices biometric prompt.",
                style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _pwCtrl,
                obscureText: true,
                enabled: !_busy,
                autofocus: true,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(labelText: "Password"),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: TibaneColors.error)),
              ],
              const Spacer(),
              FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: TibaneColors.orange,
                  foregroundColor: TibaneColors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  _busy ? "Verifying..." : "Confirm",
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
