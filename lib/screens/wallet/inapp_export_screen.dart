import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show Wallet, WalletSecret;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/logical_wallet.dart';
import '../../services/wallet/wallet_export_format.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../utils/context_extensions.dart';
import 'widgets/wallet_group_selector.dart';

/// Export the selected wallet in its original recovery format.
class InAppExportScreen extends StatefulWidget {
  const InAppExportScreen({
    super.key,
    this.showNext = false,
    this.walletIds,
    this.walletName,
  });

  final Set<String>? walletIds;
  final String? walletName;

  /// The post-create flow uses this to finish onboarding after the backup has
  /// actually been revealed. Regular exports opened from Settings keep the
  /// standard back navigation and do not show the action.
  final bool showNext;

  @override
  State<InAppExportScreen> createState() => _InAppExportScreenState();
}

class _InAppExportScreenState extends State<InAppExportScreen>
    with WidgetsBindingObserver {
  final _pwCtrl = TextEditingController();
  final _shareButtonKey = GlobalKey();
  bool _busy = false;
  bool _sharing = false;
  String? _error;
  String? _json;
  String? _filename;
  File? _tempFile;
  bool _loading = true;
  List<LogicalWallet> _groups = const [];
  String? _selectedGroupId;
  Set<String> _backupImports = const {};
  WalletSecret? _secret;
  bool _agreed = false;
  int _request = 0;

  LogicalWallet? get _selectedGroup {
    for (final group in _groups) {
      if (group.id == _selectedGroupId) return group;
    }
    return null;
  }

  bool get _exportsSeed {
    final wallets = _selectedGroup?.wallets;
    return wallets != null &&
        wallets.isNotEmpty &&
        wallets.every(
          (wallet) =>
              WalletExportPolicy.formatFor(
                wallet,
                backupImports: _backupImports,
              ) ==
              WalletExportFormat.recoveryPhrase,
        );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadWallets();
  }

  Future<void> _loadWallets() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = context.read<WalletService>();
      final client = await service.libwallet.ensureClient();
      final wallets = await client.wallets.list();
      final backupImports = wallets.any(isNormalMnemonicWallet)
          ? await WalletExportPolicy.backupImports()
          : <String>{};
      final parents = service.accountsService.attachedWalletParents;
      final activeId = service.libwallet.walletId;
      final allGroups = buildLogicalWallets(
        wallets.where((wallet) => wallet.keys.any((key) => key.isPassword)),
        attachedWalletParents: parents,
        walletGroups: service.accountsService.walletGroups,
      );
      final groups = <LogicalWallet>[];
      String? preferredId;
      for (final group in allGroups) {
        final eligible = group.wallets
            .where(
              (wallet) =>
                  wallet.keys.any((key) => key.isPassword) &&
                  (widget.walletIds == null ||
                      widget.walletIds!.contains(wallet.id)),
            )
            .toList();
        if (eligible.isEmpty) continue;
        final backupWallets = eligible
            .where(
              (wallet) =>
                  WalletExportPolicy.formatFor(
                    wallet,
                    backupImports: backupImports,
                  ) ==
                  WalletExportFormat.backup,
            )
            .toList();
        final seedGroups = <String, List<Wallet>>{};
        for (final wallet in eligible.where(
          (wallet) => !backupWallets.contains(wallet),
        )) {
          final groupId = service.accountsService.walletGroups[wallet.id];
          (seedGroups[groupId == null
                      ? 'wallet:${wallet.id}'
                      : 'group:$groupId'] ??=
                  [])
              .add(wallet);
        }
        final exportGroups = [
          if (backupWallets.isNotEmpty) LogicalWallet(backupWallets),
          for (final wallets in seedGroups.values) LogicalWallet(wallets),
        ];
        for (final exportGroup in exportGroups) {
          groups.add(exportGroup);
          if (exportGroup.containsWallet(activeId ?? '') ||
              exportGroup.containsWallet(parents[activeId] ?? '')) {
            preferredId = exportGroup.id;
          }
        }
      }
      if (widget.walletIds != null &&
          groups.isNotEmpty &&
          groups.every(
            (group) => group.wallets.every(
              (wallet) =>
                  WalletExportPolicy.formatFor(
                    wallet,
                    backupImports: backupImports,
                  ) ==
                  WalletExportFormat.backup,
            ),
          )) {
        final selection = LogicalWallet([
          for (final group in groups) ...group.wallets,
        ]);
        groups
          ..clear()
          ..add(selection);
        preferredId = selection.id;
      }
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _backupImports = backupImports;
        _selectedGroupId = preferredId ?? groups.firstOrNull?.id;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = walletErrorMessageForContext(context, error);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _request++;
    _secret = null;
    _pwCtrl.dispose();
    _cleanupTempFile();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _exportsSeed) {
      _hideSeed();
    }
  }

  void _hideSeed() {
    _request++;
    _pwCtrl.clear();
    setState(() {
      _secret = null;
      _agreed = false;
      _busy = false;
      _error = null;
    });
  }

  void _cleanupTempFile() {
    final f = _tempFile;
    _tempFile = null;
    if (f == null) return;
    // Best-effort: file may already be gone if share completed.
    unawaited(
      f.exists().then((e) async {
        if (e) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }),
    );
  }

  Future<void> _export() async {
    if (_busy || _loading) return;
    final l10n = context.l10n;
    final selected = _selectedGroup;
    if (selected == null) return;
    final seed = _exportsSeed;
    if (seed && !_agreed) return;
    final request = ++_request;
    final pw = _pwCtrl.text;
    if (pw.isEmpty) {
      setState(() => _error = l10n.exportEnterPassword);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wallet = context.read<WalletService>();
      if (seed) {
        final secret = await wallet.libwallet.exportRecoveryPhraseGroup(
          walletIds: selected.wallets.map((wallet) => wallet.id).toSet(),
          password: pw,
        );
        if (!mounted || request != _request) return;
        final state = WidgetsBinding.instance.lifecycleState;
        if (state != null && state != AppLifecycleState.resumed) return;
        _pwCtrl.clear();
        setState(() {
          _secret = secret;
          _busy = false;
        });
        return;
      }
      final json = await wallet.libwallet.exportBackupJson(
        pw,
        walletIds: selected.wallets.map((wallet) => wallet.id).toSet(),
      );
      final slug = _slugify(
        widget.walletName ?? selected.displayName('wallet'),
      );
      if (!mounted || request != _request) return;
      _pwCtrl.clear();
      setState(() {
        _json = json;
        _filename = 'tibane_${slug}_backup.json';
        _busy = false;
      });
    } catch (e) {
      // Native export errors may contain recovery material. Never log them.
      if (!mounted || request != _request) return;
      if (seed) _pwCtrl.clear();
      setState(() {
        _busy = false;
        _error =
            seed && WalletError.from(e).key != WalletErrorKey.incorrectPassword
            ? l10n.exportSeedFailed
            : walletErrorMessageForContext(context, e);
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
          files: [
            XFile(file.path, mimeType: 'application/json', name: filename),
          ],
          subject: filename,
          fileNameOverrides: [filename],
          sharePositionOrigin: anchor,
        ),
      );
    } catch (e) {
      logError('[InAppExport._share] share backup error: $e');
      if (!mounted) return;
      await _showErrorDialog(
        context.l10n.exportShareErrorTitle,
        walletErrorMessageForContext(context, e),
      );
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
      logError('[InAppExport._copy] clipboard error: $e');
      if (!mounted) return;
      final l10n = context.l10n;
      await _showErrorDialog(
        l10n.exportClipboardErrorTitle,
        l10n.exportClipboardErrorBody(walletErrorMessageForContext(context, e)),
      );
      return;
    }
    if (!mounted) return;
    context.showSnackBar(
      SnackBar(content: Text(context.l10n.exportCopiedSnack)),
    );
  }

  Future<void> _copySeed({bool passphrase = false}) async {
    final secret = _secret;
    final value = passphrase ? secret?.passphrase : secret?.mnemonic;
    if (value == null || value.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (!mounted || !identical(secret, _secret)) return;
      context.showSnackBar(
        SnackBar(content: Text(context.l10n.exportSeedCopied)),
      );
    } catch (_) {
      if (mounted && identical(secret, _secret)) {
        setState(() => _error = context.l10n.exportSeedFailed);
      }
    }
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
            child: Text(ctx.l10n.actionOk),
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
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: Text(l10n.exportWallet),
        actions: [
          if (widget.showNext && (_json != null || _secret != null))
            TextButton(
              onPressed: _sharing
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: Text(
                l10n.actionNext,
                style: const TextStyle(
                  color: TibaneColors.orange,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _groups.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _error ?? l10n.exportPrivateKeyAccount,
                      style: const TextStyle(color: TibaneColors.textMuted),
                    ),
                    if (_error != null)
                      TextButton(
                        onPressed: _loadWallets,
                        child: Text(l10n.mnemonicStartOver),
                      ),
                  ],
                ),
              )
            : _secret != null
            ? ListView(
                padding: const EdgeInsets.all(24),
                children: _buildSeed(),
              )
            : _json == null
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: _buildPassword(),
              )
            : Padding(padding: const EdgeInsets.all(24), child: _buildJson()),
      ),
    );
  }

  Widget _buildPassword() {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WalletGroupSelector(
          groups: _groups,
          selectedId: _selectedGroupId,
          enabled: !_busy && (widget.walletIds == null || _groups.length > 1),
          onChanged: (id) {
            _pwCtrl.clear();
            setState(() {
              _selectedGroupId = id;
              _agreed = false;
              _secret = null;
              _request++;
              _error = null;
            });
          },
        ),
        const SizedBox(height: 16),
        Text(
          _exportsSeed ? l10n.exportSeedPasswordHint : l10n.exportPasswordHint,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        if (_exportsSeed) ...[
          const SizedBox(height: 16),
          Text(
            l10n.exportSeedWarning,
            style: const TextStyle(color: TibaneColors.orange, height: 1.4),
          ),
          CheckboxListTile(
            key: const Key('seed-export-agree'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _agreed,
            onChanged: _busy
                ? null
                : (value) => setState(() => _agreed = value ?? false),
            title: Text(l10n.privateKeyExportAgree),
          ),
        ] else ...[
          const SizedBox(height: 12),
          Text(
            l10n.exportBackupScopeNotice,
            style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
          ),
        ],
        const SizedBox(height: 24),
        TextField(
          controller: _pwCtrl,
          obscureText: true,
          enabled: !_busy,
          autofocus: true,
          decoration: InputDecoration(labelText: l10n.labelPassword),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy || (_exportsSeed && !_agreed) ? null : _export,
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(
            _busy
                ? l10n.exportExporting
                : _exportsSeed
                ? l10n.exportShowSeedButton
                : l10n.exportShowBackupButton,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSeed() {
    final l10n = context.l10n;
    final words = _secret!.mnemonic!.trim().split(RegExp(r'\s+'));
    final passphrase = _secret!.passphrase;
    return [
      Text(
        _selectedGroup!.displayName(l10n.walletsMgmtUnnamed),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 16),
      Text(
        l10n.exportSeedHint,
        style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
      ),
      const SizedBox(height: 12),
      Text(
        l10n.exportSeedWarning,
        style: const TextStyle(color: TibaneColors.orange, height: 1.4),
      ),
      const SizedBox(height: 20),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: words.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: 52,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemBuilder: (_, index) => DecoratedBox(
          decoration: BoxDecoration(
            color: TibaneColors.darker,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: TibaneColors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Text(
                  '${index + 1}.',
                  style: monoStyle(
                    fontSize: 12,
                    color: TibaneColors.textMuted,
                  ).copyWith(letterSpacing: 0),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      words[index],
                      key: Key('exported-recovery-word-$index'),
                      style: monoStyle(fontSize: 15).copyWith(letterSpacing: 0),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: IconButton(
          key: const Key('seed-export-copy'),
          tooltip: l10n.actionCopy,
          onPressed: _copySeed,
          icon: const Icon(Icons.copy),
        ),
      ),
      if (passphrase != null && passphrase.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
          l10n.mnemonicPassphraseLabel,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.exportSeedPassphraseHint,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 12),
        Text(
          passphrase,
          key: const Key('exported-recovery-passphrase'),
          style: monoStyle(fontSize: 15).copyWith(letterSpacing: 0),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            key: const Key('seed-passphrase-copy'),
            tooltip: l10n.actionCopy,
            onPressed: () => _copySeed(passphrase: true),
            icon: const Icon(Icons.copy),
          ),
        ),
      ],
      const SizedBox(height: 16),
      OutlinedButton.icon(
        key: const Key('seed-export-hide'),
        onPressed: _hideSeed,
        icon: const Icon(Icons.visibility_off_outlined),
        label: Text(l10n.exportSeedHide),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: const TextStyle(color: TibaneColors.error)),
      ],
    ];
  }

  Widget _buildJson() {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.exportJsonHint,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
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
          label: Text(_sharing ? l10n.exportPreparing : l10n.exportShareButton),
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
          label: Text(l10n.exportCopyButton),
          style: OutlinedButton.styleFrom(
            foregroundColor: TibaneColors.text,
            side: const BorderSide(color: TibaneColors.borderHover),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.exportCopyWarning,
          style: const TextStyle(color: TibaneColors.orange, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
