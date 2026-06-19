import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../utils/log.dart';

/// Cloud-backup hub. Writes an encrypted copy of the wallet to the app's
/// documents directory; the device-level "iCloud Backup" (iOS) or "Auto
/// Backup" (Android) feature uploads that file to the user's cloud as part
/// of the normal device backup. No extra entitlements or OAuth required.
class CloudBackupScreen extends StatefulWidget {
  const CloudBackupScreen({super.key});

  @override
  State<CloudBackupScreen> createState() => _CloudBackupScreenState();
}

class _CloudBackupScreenState extends State<CloudBackupScreen> {
  DateTime? _lastBackup;
  int? _backupBytes;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    final wallet = context.read<WalletService>();
    final last = await wallet.libwallet.lastAutoBackup();
    final body = await wallet.libwallet.readAutoBackup();
    if (!mounted) return;
    setState(() {
      _lastBackup = last;
      _backupBytes = body?.length;
      _loading = false;
    });
  }

  Future<void> _backupNow() async {
    final wallet = context.read<WalletService>();
    final pw = await _promptPassword(
      title: 'Back up now',
      message:
          'Re-enter your wallet password so the encrypted backup can be '
          'written to your device\'s auto-backup directory.',
    );
    if (pw == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ts = await wallet.libwallet.writeAutoBackup(pw);
    if (!mounted) return;
    if (ts == null) {
      logError('[CloudBackup._backupNow] backup failed: ${wallet.libwallet.error}');
    }
    setState(() {
      _busy = false;
      if (ts == null) {
        _error = wallet.libwallet.error ?? 'Backup failed';
      }
    });
    await _refresh();
    if (!mounted) return;
    if (ts != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Backup written')));
    }
  }

  Future<void> _restore() async {
    final wallet = context.read<WalletService>();
    if (wallet.libwallet.hasWallet) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Disconnect the current wallet before restoring'),
        ),
      );
      return;
    }
    final json = await wallet.libwallet.readAutoBackup();
    if (json == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No local auto-backup found')),
      );
      return;
    }
    if (!mounted) return;
    final pw = await _promptPassword(
      title: 'Restore from auto-backup',
      message:
          'Enter the password for this backup. Restore writes the wallet '
          'data into the local libwallet store.',
    );
    if (pw == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await wallet.libwallet.importFromBackup(
      backupJson: json,
      password: pw,
    );
    if (!mounted) return;
    if (!ok) {
      logError('[CloudBackup._restore] restore failed: ${wallet.libwallet.error}');
    }
    setState(() {
      _busy = false;
      if (!ok) _error = wallet.libwallet.error ?? 'Restore failed';
    });
    if (ok) {
      await wallet.useLibwallet();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Wallet restored')));
    }
  }

  Future<void> _delete() async {
    final wallet = context.read<WalletService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: const Text('Delete local backup?'),
        content: const Text(
          'This removes the auto-backup file from this device. Any copy '
          'already uploaded to iCloud / Google Backup remains until the '
          'next device backup overwrites it.',
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
              'Delete',
              style: TextStyle(color: TibaneColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await wallet.libwallet.clearAutoBackup();
    if (!mounted) return;
    await _refresh();
  }

  Future<String?> _promptPassword({
    required String title,
    required String message,
  }) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: const TextStyle(color: TibaneColors.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text(
              'OK',
              style: TextStyle(color: TibaneColors.orange),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    final hasWallet = wallet.libwallet.hasWallet;
    final hasBackup = _lastBackup != null;
    final platformLabel = Platform.isIOS
        ? 'iCloud Backup'
        : 'Google Auto Backup';

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Cloud backup')),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: TibaneColors.orange),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
                children: [
                  TibaneCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.cloud_outlined,
                              color: TibaneColors.orange,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              platformLabel,
                              style: const TextStyle(
                                color: TibaneColors.text,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          Platform.isIOS
                              ? 'Files in the app\'s documents directory are '
                                    'included in iCloud Backup when you have it '
                                    'enabled in Settings > Apple ID > iCloud > '
                                    'iCloud Backup.'
                              : 'Files in the app\'s data directory are '
                                    'included in Google Auto Backup when '
                                    'enabled in Settings > System > Backup.',
                          style: monoStyle(
                            fontSize: 11,
                            color: TibaneColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TibaneCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'STATUS',
                          style: monoStyle(
                            fontSize: 10,
                            color: TibaneColors.textDim,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          hasBackup
                              ? 'Last backup: ${_formatTime(_lastBackup!)}'
                              : 'No local backup yet',
                          style: const TextStyle(color: TibaneColors.text),
                        ),
                        if (_backupBytes != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Size: ${_formatBytes(_backupBytes!)}',
                            style: monoStyle(
                              fontSize: 11,
                              color: TibaneColors.textMuted,
                            ),
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _error!,
                            style: const TextStyle(color: TibaneColors.error),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: !hasWallet || _busy ? null : _backupNow,
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: Text(_busy ? 'Working…' : 'Back up now'),
                    style: FilledButton.styleFrom(
                      backgroundColor: TibaneColors.orange,
                      foregroundColor: TibaneColors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                  if (!hasWallet)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Unlock a wallet first to back it up.',
                        style: TextStyle(color: TibaneColors.textMuted),
                      ),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: !hasBackup || hasWallet || _busy
                        ? null
                        : _restore,
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('Restore from auto-backup'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                  if (hasWallet)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Disconnect the current wallet to restore another one '
                        'from this backup.',
                        style: TextStyle(color: TibaneColors.textMuted),
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: !hasBackup || _busy ? null : _delete,
                    icon: const Icon(
                      Icons.delete_outline,
                      color: TibaneColors.error,
                    ),
                    label: const Text(
                      'Delete local backup',
                      style: TextStyle(color: TibaneColors.error),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  static String _formatTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  static String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
