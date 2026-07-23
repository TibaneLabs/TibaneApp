import 'dart:async';

import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/unified_account.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/wallet_error_display.dart';
import 'device_transfer_send_screen.dart';
import 'inapp_export_screen.dart';
import 'reset_password_screen.dart';
import 'share_labels.dart';
import '../../utils/log.dart';
import '../../utils/context_extensions.dart';

/// Wallet detail view. When [walletId] is null, falls back to the
/// active in-app wallet (legacy callers); otherwise shows the wallet
/// fetched by id via libwallet.
class WalletDetailsScreen extends StatefulWidget {
  final String? walletId;

  const WalletDetailsScreen({super.key, this.walletId});

  @override
  State<WalletDetailsScreen> createState() => _WalletDetailsScreenState();

  /// Pure decision for the detail screen's action area, extracted for tests.
  /// `showUse` — render "Use this wallet" (only for a non-active wallet).
  /// `showNeeds2fa` — render the "needs 2FA on this device" hint (a non-active
  /// wallet that has no local device share).
  @visibleForTesting
  static ({bool showUse, bool showNeeds2fa}) walletDetailActions({
    required bool isActive,
    required bool hasShareHere,
  }) {
    return (showUse: !isActive, showNeeds2fa: !isActive && !hasShareHere);
  }

  /// Minimum / maximum length for a wallet name, applied to the trimmed value.
  /// libwallet itself enforces no convention (the name is a display string),
  /// so these are app-side limits.
  static const int kNameMinLength = 3;
  static const int kNameMaxLength = 28;

  /// Validate + normalise a user-entered wallet name: trim surrounding
  /// whitespace, then require [kNameMinLength]–[kNameMaxLength] characters.
  /// Returns the cleaned `name` on success, or an `errorCode` sentinel
  /// ('too_short' / 'too_long') to be mapped to a localized message at the
  /// call site.
  @visibleForTesting
  static ({String? name, String? errorCode}) validateWalletName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.length < kNameMinLength) {
      return (name: null, errorCode: 'too_short');
    }
    if (trimmed.length > kNameMaxLength) {
      return (name: null, errorCode: 'too_long');
    }
    return (name: trimmed, errorCode: null);
  }
}

class _WalletDetailsScreenState extends State<WalletDetailsScreen> {
  lw.Wallet? _wallet;
  List<lw.Account> _accounts = const [];
  bool _loading = true;
  String? _loadError;
  bool _isActive = false;
  bool _hasShareHere = true;
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ws = context.read<WalletService>();
    final id = widget.walletId ?? ws.libwallet.walletId;
    if (id == null) {
      setState(() {
        _loading = false;
        _loadError = context.l10n.walletDetailsNoWallet;
      });
      return;
    }
    try {
      final client = await ws.libwallet.ensureClient();
      // Single source of truth: refresh once, then read this wallet's
      // filtered accounts from AccountsService (phantoms already removed).
      final wallet = await client.wallets.get(id);
      await ws.refreshAccounts();
      final isActive = id == ws.libwallet.walletId;
      final hasShareHere = await ws.libwallet.hasLocalDeviceShare(id);
      if (!mounted) return;
      setState(() {
        _wallet = wallet;
        _accounts = ws.accountsService.rawAccountsForWallet(id);
        _isActive = isActive;
        _hasShareHere = hasShareHere;
        _loading = false;
      });
    } catch (e) {
      logError('[WalletDetails._load] load wallet error: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.toString();
      });
    }
  }

  Future<void> _backup() async {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const InAppExportScreen()));
  }

  /// Reset this wallet's password via 2FA (no old password needed). On success
  /// the wallet becomes active + unlocked under the new password.
  Future<void> _resetPassword() async {
    final wallet = _wallet;
    if (wallet == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ResetPasswordScreen(walletId: wallet.id, walletName: wallet.name),
      ),
    );
    if (mounted) _load();
  }

  /// Move this wallet to another device via QR device transfer. The send
  /// screen switches to / unlocks this wallet first if it isn't the active
  /// unlocked one (only the active wallet's StoreKey share can be released).
  Future<void> _transfer() async {
    final wallet = _wallet;
    if (wallet == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DeviceTransferSendScreen(
          walletId: wallet.id,
          walletName: wallet.name,
        ),
      ),
    );
    // Switching to this wallet to transfer it may have changed active state.
    if (mounted) _load();
  }

  /// Make this (non-active) wallet the in-use one via a lockless, account-centric
  /// switch — no password. Signing authorizes per-transaction via the sheet; a
  /// wallet with no local device share prompts 2FA recovery at sign time (the
  /// "needs 2FA" hint is already shown). `setCurrentAccount` switches libwallet
  /// to the wallet, picks a compatible network, and PERSISTS the choice (so it
  /// survives a relaunch — a bare switchWallet wouldn't).
  Future<void> _use() async {
    final wallet = _wallet;
    if (wallet == null) return;
    final l10n = context.l10n;
    final ws = context.read<WalletService>();
    final name = wallet.name.isEmpty ? 'wallet' : wallet.name;
    final messenger = context.messenger;
    final target = accountForWallet(ws.accounts, wallet.id);
    if (target == null) {
      logError('[WalletDetails._use] no account found for ${wallet.id}');
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.walletDetailsCouldNotSwitch(name))),
      );
      return;
    }
    final ok = await ws.setCurrentAccount(target);
    if (!mounted) return;
    if (ok) {
      await _load(); // refresh _isActive / _hasShareHere from the new state
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.walletDetailsNowInUse(name))),
      );
    } else {
      logError('[WalletDetails._use] switch failed: ${ws.libwallet.error}');
      showWalletError(
        context,
        ws.libwallet.error ?? l10n.walletDetailsCouldNotSwitch(name),
      );
    }
  }

  List<Widget> _buildUseSection() {
    final l10n = context.l10n;
    final actions = WalletDetailsScreen.walletDetailActions(
      isActive: _isActive,
      hasShareHere: _hasShareHere,
    );
    if (!actions.showUse) return const [];
    return [
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _use,
          icon: const Icon(Icons.check_circle_outline, size: 18),
          label: Text(l10n.walletDetailsUseButton),
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
      if (actions.showNeeds2fa) ...[
        const SizedBox(height: 8),
        Text(
          l10n.walletDetailsNeeds2faHint,
          style: const TextStyle(color: TibaneColors.textMuted, fontSize: 12),
        ),
      ],
      const SizedBox(height: 20),
    ];
  }

  /// Rename this wallet via a modal text input. Validation (3–28 trimmed
  /// characters) lives in [WalletDetailsScreen.validateWalletName]; on success
  /// the header re-fetches and the wallet list refreshes on return.
  Future<void> _rename() async {
    final wallet = _wallet;
    if (wallet == null) return;
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameWalletDialog(initialName: wallet.name),
    );
    if (newName == null || !mounted) return;
    if (newName == wallet.name) return;
    final l10n = context.l10n;
    final ws = context.read<WalletService>();
    final ok = await ws.libwallet.renameWallet(wallet.id, newName);
    if (!mounted) return;
    if (ok) {
      await _load();
      if (!mounted) return;
      context.showSnackBar(
        SnackBar(content: Text(l10n.walletDetailsRenamed(newName))),
      );
    } else {
      logError('[WalletDetails._rename] rename failed: ${ws.libwallet.error}');
      showWalletError(
        context,
        ws.libwallet.error ?? l10n.walletDetailsRenameFailed,
      );
    }
  }

  Future<void> _remove() async {
    if (_removing) return;
    final wallet = _wallet;
    if (wallet == null) return;
    final l10n = context.l10n;
    final confirmed = await _confirmRemoval(context, l10n);
    if (confirmed != true) return;
    if (!mounted) return;
    final ws = context.read<WalletService>();
    setState(() => _removing = true);
    final ok = await ws.libwallet.removeWallet(wallet.id);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      _refreshAfterRemoval(ws);
    } else {
      setState(() => _removing = false);
      logError('[WalletDetails._remove] remove failed: ${ws.libwallet.error}');
      showWalletError(
        context,
        ws.libwallet.error ?? l10n.walletDetailsRemoveFailed,
      );
    }
  }

  void _refreshAfterRemoval(WalletService ws) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshAfterRemovalNow(ws));
    });
  }

  Future<void> _refreshAfterRemovalNow(WalletService ws) async {
    await ws.refreshAccounts();
    if (ws.isConnected) {
      await ws.refreshBalances();
    }
  }

  Future<bool?> _confirmRemoval(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    return showDialog<bool>(
      context: context,
      builder: (_) => _RemoveWalletDialog(l10n: l10n),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.labelWallet)),
      body: SafeArea(
        child: Builder(
          builder: (context) {
            if (_loading) {
              return const Center(
                child: CircularProgressIndicator(color: TibaneColors.orange),
              );
            }
            if (_loadError != null || _wallet == null) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _loadError ?? l10n.walletDetailsNoWallet,
                    style: const TextStyle(color: TibaneColors.textMuted),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _HeaderCard(wallet: _wallet!, onEdit: _rename),
                  const SizedBox(height: 20),
                  _SharesCard(wallet: _wallet!),
                  const SizedBox(height: 20),
                  _AccountsCard(accounts: _accounts),
                  const SizedBox(height: 20),
                  ..._buildUseSection(),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _transfer,
                      icon: const Icon(Icons.send_to_mobile, size: 16),
                      label: Text(l10n.walletDetailsTransferButton),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: TibaneColors.text,
                        side: const BorderSide(color: TibaneColors.border),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _resetPassword,
                      icon: const Icon(Icons.lock_reset, size: 16),
                      label: Text(l10n.walletDetailsResetPasswordButton),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: TibaneColors.text,
                        side: const BorderSide(color: TibaneColors.border),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ActionsRow(
                    onBackup: _removing ? null : _backup,
                    onRemove: _removing ? null : _remove,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final lw.Wallet wallet;
  final VoidCallback onEdit;

  const _HeaderCard({required this.wallet, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final threshold = wallet.keys.length >= 2 ? wallet.keys.length - 1 : 1;
    final sigAlgo = wallet.curve == 'ed25519'
        ? 'EdDSA (Solana)'
        : 'ECDSA (EVM/Bitcoin)';
    return TibaneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  wallet.name.isEmpty ? l10n.walletsMgmtUnnamed : wallet.name,
                  style: context.textTheme.titleLarge,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 20),
                color: TibaneColors.orange,
                tooltip: l10n.walletDetailsRenameTitle,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.walletDetailsWalletInfo(
              threshold,
              wallet.keys.length,
              sigAlgo,
            ),
            style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _SharesCard extends StatelessWidget {
  final lw.Wallet wallet;

  const _SharesCard({required this.wallet});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final n = (wallet.keys.length - 1).clamp(1, wallet.keys.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.walletDetailsKeySharesSection,
          style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.walletDetailsSharesDescription(n, wallet.keys.length),
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 12),
        for (final k in wallet.keys) ...[
          _ShareRow(type: k.type),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _ShareRow extends StatelessWidget {
  final String type;

  const _ShareRow({required this.type});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (icon, protection) = _meta(type, l10n);
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: TibaneColors.orange.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: TibaneColors.orange, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  shareTypeLabel(type, l10n),
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  protection,
                  style: const TextStyle(
                    color: TibaneColors.textMuted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static (IconData, String) _meta(String type, AppLocalizations l10n) {
    switch (type) {
      case 'StoreKey':
        return (Icons.phone_iphone, l10n.walletDetailsShareStoreKeyDesc);
      case 'RemoteKey':
        return (Icons.cloud_outlined, l10n.walletDetailsShareRemoteKeyDesc);
      case 'Password':
        return (Icons.password, l10n.walletDetailsSharePasswordDesc);
      case 'Plain':
        return (Icons.key_outlined, l10n.walletDetailsSharePlainDesc);
      default:
        return (Icons.help_outline, type);
    }
  }
}

class _AccountsCard extends StatelessWidget {
  final List<lw.Account> accounts;

  const _AccountsCard({required this.accounts});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (accounts.isEmpty) {
      return TibaneCard(
        child: Row(
          children: [
            const Icon(
              Icons.account_circle_outlined,
              color: TibaneColors.textMuted,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.walletDetailsNoAccounts,
                style: const TextStyle(color: TibaneColors.textMuted),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.walletDetailsAccountsSection,
          style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < accounts.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          _AccountRow(account: accounts[i]),
        ],
      ],
    );
  }
}

class _AccountRow extends StatelessWidget {
  final lw.Account account;

  const _AccountRow({required this.account});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final addr = account.address;
    final preview = addr.length > 14
        ? '${addr.substring(0, 6)}…${addr.substring(addr.length - 6)}'
        : addr;
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const Icon(
            Icons.account_circle_outlined,
            color: TibaneColors.textMuted,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  account.name.isEmpty ? account.type : account.name,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${account.type} · $preview',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
                if (account.path.isNotEmpty)
                  Text(
                    l10n.accountsDerivationPath(account.path),
                    style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RemoveWalletDialog extends StatefulWidget {
  final AppLocalizations l10n;

  const _RemoveWalletDialog({required this.l10n});

  @override
  State<_RemoveWalletDialog> createState() => _RemoveWalletDialogState();
}

class _RemoveWalletDialogState extends State<_RemoveWalletDialog> {
  late final TextEditingController _ctrl = TextEditingController();
  bool _canContinue = false;

  String get _phrase => widget.l10n.walletDetailsRemoveConfirmPhrase;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final next = value.trim() == _phrase;
    if (next == _canContinue) return;
    setState(() => _canContinue = next);
  }

  void _close(bool result) {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(result);
  }

  void _submit() {
    if (_canContinue) _close(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      scrollable: true,
      title: Text(l10n.walletDetailsRemoveTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: TibaneColors.error.withValues(alpha: 0.12),
              border: Border.all(
                color: TibaneColors.error.withValues(alpha: 0.55),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: TibaneColors.error,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.walletDetailsRemoveBody,
                    style: const TextStyle(
                      color: TibaneColors.text,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            l10n.walletDetailsRemoveConfirmInstruction(_phrase),
            style: const TextStyle(color: TibaneColors.textMuted, height: 1.35),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _ctrl,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            style: const TextStyle(color: TibaneColors.text),
            decoration: InputDecoration(
              hintText: l10n.walletDetailsRemoveConfirmHint(_phrase),
            ),
            onChanged: _onChanged,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => _close(false),
          child: Text(l10n.actionCancel),
        ),
        TextButton(
          onPressed: _canContinue ? _submit : null,
          child: Text(
            l10n.walletDetailsRemoveConfirmButton,
            style: TextStyle(
              color: _canContinue ? TibaneColors.error : TibaneColors.textDim,
            ),
          ),
        ),
      ],
    );
  }
}

/// Modal text input for renaming a wallet. Returns the cleaned, validated
/// name via `Navigator.pop`, or null when cancelled. Validation mirrors
/// [WalletDetailsScreen.validateWalletName] and is surfaced inline.
class _RenameWalletDialog extends StatefulWidget {
  final String initialName;

  const _RenameWalletDialog({required this.initialName});

  @override
  State<_RenameWalletDialog> createState() => _RenameWalletDialogState();
}

class _RenameWalletDialogState extends State<_RenameWalletDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initialName,
  );
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = context.l10n;
    final result = WalletDetailsScreen.validateWalletName(_ctrl.text);
    if (result.errorCode != null) {
      setState(() {
        _error = result.errorCode == 'too_short'
            ? l10n.walletDetailsNameTooShort(WalletDetailsScreen.kNameMinLength)
            : l10n.walletDetailsNameTooLong(WalletDetailsScreen.kNameMaxLength);
      });
      return;
    }
    Navigator.of(context).pop(result.name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      title: Text(l10n.walletDetailsRenameTitle),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: WalletDetailsScreen.kNameMaxLength,
        textInputAction: TextInputAction.done,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: l10n.labelWalletName,
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(
            l10n.actionSave,
            style: const TextStyle(color: TibaneColors.orange),
          ),
        ),
      ],
    );
  }
}

class _ActionsRow extends StatelessWidget {
  final VoidCallback? onBackup;
  final VoidCallback? onRemove;

  const _ActionsRow({required this.onBackup, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onBackup,
            icon: const Icon(Icons.download_outlined, size: 16),
            label: Text(l10n.walletDetailsExportButton),
            style: OutlinedButton.styleFrom(
              foregroundColor: TibaneColors.text,
              side: const BorderSide(color: TibaneColors.border),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline, size: 16),
            label: Text(l10n.actionRemove),
            style: OutlinedButton.styleFrom(
              foregroundColor: TibaneColors.error,
              side: const BorderSide(color: TibaneColors.error),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }
}
