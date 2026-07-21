import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/unified_account.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../widgets/wallet_error_display.dart';
import 'inapp_unlock_screen.dart';
import '../../utils/context_extensions.dart';

/// Restore an in-app wallet from a Tibane backup: pick the exported file
/// (primary) or paste the backup JSON (fallback for small payloads), then
/// enter the wallet password. Pops `true` on success.
class InAppBackupRestoreScreen extends StatefulWidget {
  const InAppBackupRestoreScreen({super.key});

  @override
  State<InAppBackupRestoreScreen> createState() =>
      _InAppBackupRestoreScreenState();
}

class _InAppBackupRestoreScreenState extends State<InAppBackupRestoreScreen> {
  static const int _maxBackupBytes = 1024 * 1024; // 1 MB hard cap.

  final _jsonCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _loadedFilename;

  @override
  void dispose() {
    _jsonCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
      if (!mounted) return;
      if (result == null || result.files.isEmpty) {
        setState(() => _busy = false);
        return;
      }
      final picked = result.files.single;
      if (picked.size > _maxBackupBytes) {
        throw const FormatException(
          'File is larger than 1 MB. Backups should be much smaller. '
          'Double-check you picked the right file.',
        );
      }
      final bytes =
          picked.bytes ??
          (picked.path != null ? await File(picked.path!).readAsBytes() : null);
      if (!mounted) return;
      if (bytes == null) {
        throw const FormatException('Could not read the selected file');
      }
      if (bytes.length > _maxBackupBytes) {
        throw const FormatException('File is larger than 1 MB');
      }
      String text;
      try {
        text = utf8.decode(bytes);
      } catch (_) {
        throw const FormatException(
          'File is not text. Pick the backup JSON exported from Tibane',
        );
      }
      _jsonCtrl.text = text;
      setState(() {
        _busy = false;
        _loadedFilename = picked.name;
      });
    } catch (e) {
      if (!mounted) return;
      logError('[InAppBackupRestore._pickFile] file pick error: $e');
      setState(() {
        _busy = false;
        _error = WalletError.from(e).message;
      });
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    final l10n = context.l10n;
    final json = _jsonCtrl.text.trim();
    final pw = _pwCtrl.text;
    if (json.isEmpty) {
      setState(() => _error = l10n.backupRestoreNoJson);
      return;
    }
    if (pw.isEmpty) {
      setState(() => _error = l10n.backupRestoreNoPassword);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wallet = context.read<WalletService>();
      final ok = await wallet.libwallet.importFromBackup(
        backupJson: json,
        password: pw,
      );
      if (!mounted) return;
      if (ok) {
        // Restore ADDS the wallet; make it the current account so the user
        // lands on it (else the account model stays on the old current).
        final restoredId = wallet.libwallet.walletId;
        await wallet.refreshAccounts();
        if (!mounted) return;
        final acct = restoredId == null
            ? null
            : accountForWallet(wallet.accounts, restoredId);
        if (acct != null) {
          await wallet.setCurrentAccount(acct);
        } else {
          await wallet.useLibwallet();
        }
        if (!mounted) return;
        // A backup never contains this device's signing key (StoreKey) — it's
        // device-only for security. So a freshly restored wallet CAN'T sign yet;
        // the restore only becomes usable after "Set up this device" mints a
        // local share via 2FA. Steer the user straight there and explain why,
        // rather than dropping them on a wallet that silently can't send.
        final setupNow = await _promptFinishSetup();
        if (!mounted) return;
        if (setupNow && restoredId != null) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => InAppUnlockScreen(walletId: restoredId),
            ),
          );
          if (!mounted) return;
        }
        Navigator.of(context).pop(true);
      } else {
        final err = wallet.libwallet.error ?? 'Import failed';
        logError('[InAppBackupRestore._restore] import failed: $err');
        // SnackBar in addition to the inline error — the inline message sits
        // below the password field and can hide under the keyboard.
        showWalletError(context, err);
        setState(() {
          _busy = false;
          _error = err;
        });
      }
    } catch (e) {
      logError('[InAppBackupRestore._restore] restore error: $e');
      if (!mounted) return;
      final err = WalletError.from(e).message;
      showWalletError(context, err);
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  /// Explain why a restored wallet still needs a device-side setup step, and
  /// offer to run it now. Returns true = the user chose "Set up now".
  Future<bool> _promptFinishSetup() async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(l10n.backupRestoreSetupTitle),
        content: Text(
          l10n.backupRestoreSetupBody,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              l10n.backupRestoreSetupLater,
              style: const TextStyle(color: TibaneColors.textMuted),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: TibaneColors.orange,
              foregroundColor: TibaneColors.black,
            ),
            child: Text(l10n.backupRestoreSetupNow),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.backupRestoreTitle)),
      body: SafeArea(
        // Tap anywhere outside an input to drop the keyboard. Without this
        // the multiline JSON field has no other way to unfocus, since the
        // surrounding ScrollView doesn't consume taps by default.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.unfocus(),
          // Outer column splits the screen into a scrollable body and a
          // pinned bottom bar so the Restore button is always reachable —
          // it stays just above the keyboard when one is open.
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.backupRestoreHint,
                        style: const TextStyle(
                          color: TibaneColors.textMuted,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _busy ? null : _pickFile,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: Text(
                          _busy
                              ? l10n.commonWorking
                              : l10n.backupRestoreOpenButton,
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: TibaneColors.orange,
                          foregroundColor: TibaneColors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                      if (_loadedFilename != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          l10n.backupRestoreLoaded(_loadedFilename!),
                          style: const TextStyle(
                            color: TibaneColors.textMuted,
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          const Expanded(
                            child: Divider(color: TibaneColors.border),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              l10n.backupRestoreOrPaste,
                              style: const TextStyle(
                                color: TibaneColors.textDim,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          const Expanded(
                            child: Divider(color: TibaneColors.border),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Bounded multi-line field — internal scroll handles
                      // long JSON payloads. A fill-remaining Expanded here
                      // fights the keyboard inset and squeezes itself to
                      // zero height when resizeToAvoidBottomInset kicks in.
                      TextField(
                        controller: _jsonCtrl,
                        enabled: !_busy,
                        minLines: 4,
                        maxLines: 8,
                        keyboardType: TextInputType.multiline,
                        textAlignVertical: TextAlignVertical.top,
                        style: monoStyle(
                          fontSize: 11,
                          color: TibaneColors.text,
                        ),
                        decoration: InputDecoration(
                          labelText: l10n.backupRestoreJsonLabel,
                          alignLabelWithHint: true,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) {
                          if (_loadedFilename != null) {
                            setState(() => _loadedFilename = null);
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _pwCtrl,
                        obscureText: true,
                        enabled: !_busy,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _busy ? null : _restore(),
                        decoration: InputDecoration(
                          labelText: l10n.labelPassword,
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(color: TibaneColors.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _restore,
                    style: FilledButton.styleFrom(
                      backgroundColor: TibaneColors.orange,
                      foregroundColor: TibaneColors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                      _busy
                          ? l10n.backupRestoreRestoring
                          : l10n.backupRestoreButton,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
