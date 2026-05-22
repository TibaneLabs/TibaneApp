import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';

/// Import an existing in-app wallet either by picking a backup file (primary)
/// or pasting the JSON directly (fallback for small payloads).
class InAppImportScreen extends StatefulWidget {
  const InAppImportScreen({super.key});

  @override
  State<InAppImportScreen> createState() => _InAppImportScreenState();
}

class _InAppImportScreenState extends State<InAppImportScreen> {
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
          'File is larger than 1 MB — backups should be much smaller. '
          'Double-check you picked the right file.',
        );
      }
      final bytes = picked.bytes ??
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
          'File is not text — pick the backup JSON exported from Tibane',
        );
      }
      _jsonCtrl.text = text;
      setState(() {
        _busy = false;
        _loadedFilename = picked.name;
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('File pick failed: $e');
      setState(() {
        _busy = false;
        _error = _friendlyError(e);
      });
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    final json = _jsonCtrl.text.trim();
    final pw = _pwCtrl.text;
    if (json.isEmpty) {
      setState(() => _error = 'Open a backup file or paste the backup JSON');
      return;
    }
    if (pw.isEmpty) {
      setState(() => _error = 'Enter the wallet password');
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
        await wallet.useLibwallet();
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _busy = false;
          _error = wallet.libwallet.error ?? 'Import failed';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _friendlyError(e);
      });
    }
  }

  String _friendlyError(Object e) {
    if (e is FormatException) return e.message;
    return e.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Import wallet')),
      body: SafeArea(
        // Tap anywhere outside an input to drop the keyboard. Without this
        // the multiline JSON field has no other way to unfocus, since the
        // surrounding ScrollView doesn't consume taps by default.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
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
                      const Text(
                        'Open the backup file exported from another device, or paste '
                        'the backup JSON. Then enter the same password used when the '
                        'wallet was created.',
                        style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _busy ? null : _pickFile,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: Text(_busy ? 'Working…' : 'Open backup file'),
                        style: FilledButton.styleFrom(
                          backgroundColor: TibaneColors.orange,
                          foregroundColor: TibaneColors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                      if (_loadedFilename != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Loaded: $_loadedFilename',
                          style: const TextStyle(
                            color: TibaneColors.textMuted,
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        children: const [
                          Expanded(child: Divider(color: TibaneColors.border)),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              'Or paste JSON',
                              style: TextStyle(
                                color: TibaneColors.textDim,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Expanded(child: Divider(color: TibaneColors.border)),
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
                        style: monoStyle(fontSize: 11, color: TibaneColors.text),
                        decoration: const InputDecoration(
                          labelText: 'Backup JSON',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
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
                        decoration: const InputDecoration(labelText: 'Password'),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: const TextStyle(color: TibaneColors.error)),
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
                      _busy ? 'Restoring…' : 'Restore wallet',
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
