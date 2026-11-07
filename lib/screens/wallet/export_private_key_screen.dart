import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show KeyDescription, WalletSecret;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/unified_account.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import 'widgets/sign_sheet.dart';

class ExportPrivateKeyScreen extends StatefulWidget {
  const ExportPrivateKeyScreen({super.key, required this.account});
  final UnifiedAccount account;

  @override
  State<ExportPrivateKeyScreen> createState() => _ExportPrivateKeyScreenState();
}

class _ExportPrivateKeyScreenState extends State<ExportPrivateKeyScreen>
    with WidgetsBindingObserver {
  bool _agreed = false;
  bool _busy = false;
  bool _exporting = false;
  WalletSecret? _secret;
  String? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _request++;
    _secret = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _secret != null) {
      setState(() {
        _request++;
        _secret = null;
        _agreed = false;
        _busy = false;
        _exporting = false;
      });
    }
  }

  Future<void> _reveal() async {
    if (!_agreed || _busy) return;
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final backend = context.read<WalletService>().libwallet;
      final client = await backend.ensureClient();
      final account = await client.accounts.get(widget.account.accountId!);
      final wallet = await client.wallets.get(account.wallet);
      if (account.wallet != widget.account.walletId ||
          account.address != widget.account.address ||
          account.index != 0 ||
          wallet.threshold != 0 ||
          wallet.keys.length != 1) {
        if (mounted) {
          setState(() => _error = context.l10n.privateKeyExportUnavailable);
        }
        return;
      }
      if (!mounted || request != _request) return;
      final l10n = context.l10n;
      final keys = await showSignSheet(
        context,
        wallet: wallet,
        readStoreKey: (key, password) => backend.readStoreKeyPrivateForWallet(
          wallet.id,
          key,
          password: password,
        ),
        title: l10n.privateKeyExportTitle,
        subtitlePurpose: l10n.privateKeyExportPurpose,
        actionLabel: l10n.actionConfirm,
      );
      if (keys == null || !mounted || request != _request) return;
      setState(() => _exporting = true);
      final secret = await backend.exportImportedPrivateKey(
        accountId: account.id,
        keys: [
          for (final key in keys)
            KeyDescription(
              type: key.type ?? wallet.keys.single.type,
              key: key.key,
              id: key.id,
            ),
        ],
      );
      if (!mounted || request != _request) return;
      final state = WidgetsBinding.instance.lifecycleState;
      if (state != null && state != AppLifecycleState.resumed) return;
      setState(() => _secret = secret);
    } catch (_) {
      // Never log native export errors: they may contain secret material.
      if (mounted && request == _request) {
        setState(() => _error = context.l10n.privateKeyExportFailed);
      }
    } finally {
      if (mounted && request == _request) {
        setState(() {
          _busy = false;
          _exporting = false;
        });
      }
    }
  }

  Future<void> _copy() async {
    final key = _secret?.privateKey;
    if (key == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: key));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.copiedToast(context.l10n.privateKeyExportTitle),
          ),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.privateKeyExportFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.privateKeyExportTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              widget.account.accountName.isNotEmpty
                  ? widget.account.accountName
                  : widget.account.label,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              abbreviateAccountAddress(widget.account.address),
              style: monoStyle(),
            ),
            const SizedBox(height: 24),
            const Icon(
              Icons.warning_amber_rounded,
              color: TibaneColors.orange,
              size: 36,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.privateKeyExportDisclaimer,
              style: const TextStyle(color: TibaneColors.orange, fontSize: 16),
            ),
            const SizedBox(height: 16),
            if (_secret == null) ...[
              CheckboxListTile(
                key: const Key('private-key-export-agree'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _agreed,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _agreed = value ?? false),
                title: Text(l10n.privateKeyExportAgree),
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('private-key-export-reveal'),
                onPressed: _agreed && !_busy ? _reveal : null,
                child: _exporting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.privateKeyExportReveal),
              ),
            ] else ...[
              if (_secret!.format == 'scalar') ...[
                Text(
                  l10n.privateKeyExportScalarWarning,
                  style: const TextStyle(color: TibaneColors.orange),
                ),
                const SizedBox(height: 12),
              ],
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: TibaneColors.darker,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: TibaneColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // No selection menu: the dedicated copy action is explicit.
                    Text(
                      _secret!.privateKey!,
                      key: const Key('exported-private-key'),
                      style: monoStyle(fontSize: 15),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        key: const Key('private-key-export-copy'),
                        tooltip: l10n.actionCopy,
                        onPressed: _copy,
                        icon: const Icon(Icons.copy),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: TibaneColors.error)),
            ],
          ],
        ),
      ),
    );
  }
}
