import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show KeyDescription, WalletSecret;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/app_lock_controller.dart';
import '../../services/wallet/signing.dart';
import '../../services/wallet/unified_account.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';

class ExportPrivateKeyScreen extends StatefulWidget {
  const ExportPrivateKeyScreen({
    super.key,
    required this.account,
    this.authenticator,
  });
  final UnifiedAccount account;
  final AppLockAuthenticator? authenticator;

  @override
  State<ExportPrivateKeyScreen> createState() => _ExportPrivateKeyScreenState();
}

class _ExportPrivateKeyScreenState extends State<ExportPrivateKeyScreen>
    with WidgetsBindingObserver {
  late final _authenticator =
      widget.authenticator ?? DeviceAppLockAuthenticator();
  bool _agreed = false;
  bool _busy = false;
  bool _exporting = false;
  bool _authenticating = false;
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
    if (state != AppLifecycleState.resumed &&
        (_secret != null ||
            (_busy &&
                (!_authenticating || state != AppLifecycleState.inactive)))) {
      setState(() {
        _request++;
        _secret = null;
        _agreed = false;
        _busy = false;
        _exporting = false;
      });
    }
  }

  bool _canReveal(int request) {
    final state = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        request == _request &&
        (state == null || state == AppLifecycleState.resumed);
  }

  Future<void> _reveal() async {
    if (!_agreed || _busy) return;
    final l10n = context.l10n;
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
          account.pubkey != wallet.pubkey ||
          !isSingleDeviceKeyWallet(wallet)) {
        if (_canReveal(request)) {
          setState(() => _error = l10n.privateKeyExportUnavailable);
        }
        return;
      }
      if (!_canReveal(request)) return;
      var authorized = false;
      _authenticating = true;
      try {
        authorized = await _authenticator.authenticate(
          l10n.privateKeyExportAuthReason,
          AppLockAuthentication.deviceOwner,
        );
      } catch (_) {
        // No fallback to an unlocked app session.
      } finally {
        _authenticating = false;
      }
      if (!_canReveal(request)) return;
      if (!authorized) {
        setState(() => _error = l10n.appLockAuthenticationFailed);
        return;
      }
      setState(() => _exporting = true);
      final storeKey = wallet.keys.single;
      final key = await backend.readStoreKeyPrivateForWallet(
        wallet.id,
        storeKey,
      );
      if (!_canReveal(request)) return;
      if (key == null || key.isEmpty) {
        setState(() => _error = l10n.privateKeyExportFailed);
        return;
      }
      final secret = await backend.exportImportedPrivateKey(
        accountId: account.id,
        keys: [KeyDescription(type: storeKey.type, key: key, id: storeKey.id)],
      );
      if (!_canReveal(request)) return;
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
