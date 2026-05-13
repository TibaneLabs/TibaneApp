import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';

/// Two-step export flow: confirm password, then offer a native share sheet
/// (primary) plus a clipboard fallback for the encrypted backup JSON.
class InAppExportScreen extends StatefulWidget {
  const InAppExportScreen({super.key});

  @override
  State<InAppExportScreen> createState() => _InAppExportScreenState();
}

class _InAppExportScreenState extends State<InAppExportScreen> {
  final _pwCtrl = TextEditingController();
  final _shareButtonKey = GlobalKey();
  bool _busy = false;
  bool _sharing = false;
  String? _error;
  String? _json;
  String? _filename;
  File? _tempFile;

  @override
  void dispose() {
    _pwCtrl.dispose();
    _cleanupTempFile();
    super.dispose();
  }

  void _cleanupTempFile() {
    final f = _tempFile;
    _tempFile = null;
    if (f == null) return;
    // Best-effort: file may already be gone if share completed.
    unawaited(f.exists().then((e) async {
      if (e) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }));
  }

  Future<void> _export() async {
    final pw = _pwCtrl.text;
    if (pw.isEmpty) {
      setState(() => _error = 'Enter your wallet password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wallet = context.read<WalletService>();
      final json = await wallet.libwallet.exportBackupJson(pw);
      final slug = _slugify(wallet.libwallet.walletName ?? 'wallet');
      if (!mounted) return;
      setState(() {
        _json = json;
        _filename = 'tibane_${slug}_backup.json';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _share() async {
    if (_sharing) return;
    final json = _json;
    final filename = _filename;
    if (json == null || filename == null) return;

    // Resolve the iPad popover anchor before any async gap so we don't
    // reach for a stale BuildContext after awaits.
    Rect? anchor;
    final ctx = _shareButtonKey.currentContext;
    if (ctx != null) {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        anchor = box.localToGlobal(Offset.zero) & box.size;
      }
    }

    setState(() => _sharing = true);
    File? file;
    try {
      final dir = await getTemporaryDirectory();
      file = File('${dir.path}/$filename');
      await file.writeAsString(json, flush: true);
      _tempFile = file;

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/json', name: filename)],
          subject: filename,
          fileNameOverrides: [filename],
          sharePositionOrigin: anchor,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      await _showErrorDialog('Could not share backup', e.toString());
    } finally {
      // Scrub the temp file regardless of share outcome.
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        if (identical(_tempFile, file)) _tempFile = null;
      }
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _copy() async {
    final json = _json;
    if (json == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: json));
    } catch (e) {
      if (!mounted) return;
      await _showErrorDialog(
        'Clipboard rejected the backup',
        'Some devices block large payloads from the clipboard. '
            'Use the Share button instead. ($e)',
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Backup copied to clipboard')),
    );
  }

  Future<void> _showErrorDialog(String title, String body) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  static String _slugify(String input) {
    final lower = input.toLowerCase();
    final replaced = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final trimmed = replaced.replaceAll(RegExp(r'^_+|_+$'), '');
    return trimmed.isEmpty ? 'wallet' : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Export wallet')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _json == null ? _buildPassword() : _buildJson(),
        ),
      ),
    );
  }

  Widget _buildPassword() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Confirm your wallet password to display the encrypted backup. '
          'Keep this backup secret — anyone with it plus your password '
          'can restore your wallet.',
          style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _pwCtrl,
          obscureText: true,
          enabled: !_busy,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const Spacer(),
        FilledButton(
          onPressed: _busy ? null : _export,
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(
            _busy ? 'Exporting…' : 'Show backup',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildJson() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Save this backup to a safe place (cloud drive, password manager, '
          'encrypted note). To restore, open it from the import flow on '
          'this or another device and enter the same password.',
          style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: TibaneColors.darker,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: TibaneColors.border),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                _json!,
                style: monoStyle(fontSize: 11, color: TibaneColors.text),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: _shareButtonKey,
          onPressed: _sharing ? null : _share,
          icon: const Icon(Icons.ios_share, size: 18),
          label: Text(_sharing ? 'Preparing…' : 'Share backup file'),
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _sharing ? null : _copy,
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy to clipboard'),
          style: OutlinedButton.styleFrom(
            foregroundColor: TibaneColors.text,
            side: const BorderSide(color: TibaneColors.borderHover),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Copy may not work for large backups on some Android devices — '
          'prefer Share.',
          style: TextStyle(color: TibaneColors.textDim, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
