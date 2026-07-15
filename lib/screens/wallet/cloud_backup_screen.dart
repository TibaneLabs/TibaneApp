import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';

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
    final l10n = context.l10n;
    final wallet = context.read<WalletService>();
    final pw = await _promptPassword(
      title: l10n.cloudBackupNowButton,
      message: l10n.cloudBackupNowMessage,
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
        _error = WalletError.from(
          wallet.libwallet.error ?? 'Backup failed',
        ).message;
      }
    });
    await _refresh();
    if (!mounted) return;
    if (ts != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.cloudBackupWritten)),
      );
    }
  }

  Future<void> _restore() async {
    final l10n = context.l10n;
    final wallet = context.read<WalletService>();
    if (wallet.libwallet.hasWallet) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cloudBackupDisconnectFirst)),
      );
      return;
    }
    final json = await wallet.libwallet.readAutoBackup();
    if (json == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.cloudBackupNoBackup)),
      );
      return;
    }
    if (!mounted) return;
    final pw = await _promptPassword(
      title: l10n.cloudBackupRestoreButton,
      message: l10n.cloudBackupRestoreMessage,
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
      if (!ok) {
        _error = WalletError.from(
          wallet.libwallet.error ?? 'Restore failed',
        ).message;
      }
    });
    if (ok) {
      await wallet.useLibwallet();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.cloudBackupRestored)),
      );
    }
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final wallet = context.read<WalletService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(l10n.cloudBackupDeleteTitle),
        content: Text(
          l10n.cloudBackupDeleteBody,
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
              l10n.actionDelete,
              style: const TextStyle(color: TibaneColors.error),
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
      builder: (ctx) {
        final l10n = ctx.l10n;
        return AlertDialog(
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
                decoration: InputDecoration(labelText: l10n.labelPassword),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.actionCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(
                l10n.actionOk,
                style: const TextStyle(color: TibaneColors.orange),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wallet = context.watch<WalletService>();
    final hasWallet = wallet.libwallet.hasWallet;
    final hasBackup = _lastBackup != null;
    // Platform labels are proper nouns — not translated.
    final platformLabel = Platform.isIOS ? 'iCloud Backup' : 'Google Auto Backup';

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.cloudBackupTitle)),
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
                              ? l10n.cloudBackupHintIos
                              : l10n.cloudBackupHintAndroid,
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
                          l10n.cloudBackupStatusLabel,
                          style: monoStyle(
                            fontSize: 10,
                            color: TibaneColors.textDim,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          hasBackup
                              ? l10n.cloudBackupLastBackup(_formatTime(_lastBackup!))
                              : l10n.cloudBackupNone,
                          style: const TextStyle(color: TibaneColors.text),
                        ),
                        if (_backupBytes != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            l10n.cloudBackupSize(_formatBytes(_backupBytes!)),
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
                    label: Text(_busy ? l10n.commonWorking : l10n.cloudBackupNowButton),
                    style: FilledButton.styleFrom(
                      backgroundColor: TibaneColors.orange,
                      foregroundColor: TibaneColors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                  if (!hasWallet)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        l10n.cloudBackupUnlockFirst,
                        style: const TextStyle(color: TibaneColors.textMuted),
                      ),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: !hasBackup || hasWallet || _busy
                        ? null
                        : _restore,
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: Text(l10n.cloudBackupRestoreButton),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                  if (hasWallet)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        l10n.cloudBackupDisconnectHint,
                        style: const TextStyle(color: TibaneColors.textMuted),
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: !hasBackup || _busy ? null : _delete,
                    icon: const Icon(
                      Icons.delete_outline,
                      color: TibaneColors.error,
                    ),
                    label: Text(
                      l10n.cloudBackupDeleteButton,
                      style: const TextStyle(color: TibaneColors.error),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  String _formatTime(DateTime t) {
    final l10n = context.l10n;
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return l10n.cloudBackupTimeJustNow;
    if (diff.inMinutes < 60) return l10n.cloudBackupTimeMinutes(diff.inMinutes);
    if (diff.inHours < 24) return l10n.cloudBackupTimeHours(diff.inHours);
    if (diff.inDays < 7) return l10n.cloudBackupTimeDays(diff.inDays);
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  static String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
