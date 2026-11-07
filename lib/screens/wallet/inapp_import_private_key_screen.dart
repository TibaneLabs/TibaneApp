import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/logical_wallet.dart';
import '../../services/wallet/libwallet_backend.dart';
import '../../services/wallet/solana_private_key.dart';
import '../../services/wallet/unified_account.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/context_extensions.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import 'widgets/wallet_group_selector.dart';

enum _Step { input, importing, done, error }

enum PrivateKeyImportChain { solana, ethereum }

/// Imports a Solana or Ethereum private key as a device-protected account.
/// Imported accounts remain single-key accounts. The raw key is cleared after
/// import and is never logged or persisted by the Flutter layer.
class InAppImportPrivateKeyScreen extends StatefulWidget {
  const InAppImportPrivateKeyScreen({
    super.key,
    this.groups = const [],
    this.target,
  });

  final List<LogicalWallet> groups;
  final UnifiedAccount? target;

  @override
  State<InAppImportPrivateKeyScreen> createState() =>
      _InAppImportPrivateKeyScreenState();
}

class _InAppImportPrivateKeyScreenState
    extends State<InAppImportPrivateKeyScreen> {
  final _keyCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  _Step _step = _Step.input;
  bool _showPrivateKey = false;
  bool _pasting = false;
  bool _busy = false;
  String? _error;
  String? _importedAddress;
  String? _selectedGroupId;
  PrivateKeyImportChain _selectedChain = PrivateKeyImportChain.solana;

  LogicalWallet? get _selectedGroup {
    if (widget.groups.isEmpty) return null;
    return widget.groups.firstWhere(
      (group) => group.id == _selectedGroupId,
      orElse: () => widget.groups.first,
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.groups.isNotEmpty) {
      _selectedGroupId = widget.groups
          .firstWhere(
            (group) =>
                widget.target?.walletId != null &&
                group.containsWallet(widget.target!.walletId!),
            orElse: () => widget.groups.first,
          )
          .id;
    }
  }

  @override
  void dispose() {
    _keyCtrl.clear();
    _keyCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pastePrivateKey() async {
    if (_busy || _pasting) return;
    final chain = _selectedChain;
    final before = _keyCtrl.text;
    setState(() {
      _pasting = true;
      _error = null;
    });
    try {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted ||
          _busy ||
          _step != _Step.input ||
          chain != _selectedChain ||
          before != _keyCtrl.text) {
        return;
      }
      final text = clipboard?.text?.trim();
      if (text == null || text.isEmpty) {
        setState(() => _error = context.l10n.wcSessionsClipboardEmpty);
        return;
      }
      _keyCtrl.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    } catch (_) {
      if (mounted &&
          !_busy &&
          _step == _Step.input &&
          chain == _selectedChain &&
          before == _keyCtrl.text) {
        setState(() => _error = context.l10n.privateKeyPasteFailed);
      }
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  Future<void> _continue() async {
    final l10n = context.l10n;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.privateKeyNameRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_selectedChain == PrivateKeyImportChain.solana) {
        await normalizeSolanaPrivateKey(_keyCtrl.text);
      } else {
        normalizeEthereumPrivateKey(_keyCtrl.text);
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
      });
      await _import();
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _selectedChain == PrivateKeyImportChain.solana
            ? l10n.privateKeyInvalidSolana
            : l10n.privateKeyInvalidEthereum;
      });
    }
  }

  Future<void> _import() async {
    setState(() {
      _step = _Step.importing;
      _error = null;
    });
    try {
      // Keep the normalized secret local to the native import call rather than
      // retaining a second copy after import.
      final isSolana = _selectedChain == PrivateKeyImportChain.solana;
      final solanaKey = isSolana
          ? await normalizeSolanaPrivateKey(_keyCtrl.text)
          : null;
      final privateKey =
          solanaKey?.seedHex ??
          normalizeEthereumPrivateKey(_keyCtrl.text).privateKeyHex;
      if (!mounted) return;
      final wallet = context.read<WalletService>();
      final selectedGroup = _selectedGroup;
      final parentWalletId = selectedGroup
          ?.walletForChain(isSolana ? 'solana' : 'ethereum')
          ?.id;
      final accountName = _nameCtrl.text.trim();
      final walletName =
          selectedGroup?.displayName(context.l10n.walletsMgmtUnnamed) ??
          accountName;
      final imported = await wallet.libwallet.importPrivateKey(
        privateKey: privateKey,
        curve: isSolana ? 'ed25519' : 'secp256k1',
        accountType: isSolana ? 'solana' : 'ethereum',
        walletName: walletName,
        accountName: accountName,
        expectedAddress: solanaKey?.address,
        format: isSolana ? 'seed' : null,
      );
      _keyCtrl.clear();
      if (parentWalletId != null) {
        await wallet.accountsService.attachWalletAccount(
          childWalletId: imported.wallet.id,
          parentWalletId: parentWalletId,
        );
      }
      await wallet.useLibwallet();
      await wallet.refreshAccounts();
      UnifiedAccount? importedAccount;
      for (final account in wallet.accounts) {
        if (account.accountId == imported.account.id) {
          importedAccount = account;
          break;
        }
      }
      if (importedAccount != null) {
        await wallet.setCurrentAccount(importedAccount);
      }
      if (!mounted) return;
      setState(() {
        _importedAddress = imported.account.address;
        _step = _Step.done;
      });
    } on PrivateKeyAccountExistsException catch (e) {
      _keyCtrl.clear();
      if (!mounted) return;
      setState(() {
        _step = _Step.input;
        _busy = false;
      });
      await _showExistingAccount(e);
    } catch (e) {
      logError('[ImportPrivateKey._import] import error: $e');
      if (!mounted) return;
      setState(() {
        _error = e is PrivateKeySecureStorageException
            ? context.l10n.privateKeySecureStorageUnavailable
            : e is PrivateKeyAddressMismatchException
            ? context.l10n.privateKeyInvalidSolana
            : walletErrorMessageForContext(context, e);
        _step = _Step.error;
      });
    }
  }

  Future<void> _showExistingAccount(
    PrivateKeyAccountExistsException duplicate,
  ) async {
    final l10n = context.l10n;
    final account = duplicate.account;
    final open = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(l10n.privateKeyAlreadyImportedTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.privateKeyAlreadyImportedBody),
            const SizedBox(height: 16),
            if (account.name.trim().isNotEmpty) Text(account.name),
            const SizedBox(height: 4),
            Text(
              abbreviateAccountAddress(account.address),
              style: monoStyle(fontSize: 13, color: TibaneColors.textMuted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.actionCancel),
          ),
          TextButton.icon(
            key: const Key('open-existing-import-account'),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.account_circle_outlined),
            label: Text(l10n.privateKeyOpenExistingAccount),
          ),
        ],
      ),
    );
    if (open != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final wallet = context.read<WalletService>();
      await wallet.refreshAccounts();
      final existing = wallet.accounts
          .where(
            (a) =>
                a.isInApp &&
                a.accountId == account.id &&
                a.chain == account.type,
          )
          .firstOrNull;
      if (existing == null || !await wallet.setCurrentAccount(existing)) {
        throw StateError(l10n.accountSwitcherSwitchFailed);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() => _error = walletErrorMessageForContext(context, error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: Text(
          l10n.privateKeyTitle,
          style: _step == _Step.done
              ? Theme.of(context).appBarTheme.titleTextStyle?.copyWith(
                  fontSize:
                      (Theme.of(context).appBarTheme.titleTextStyle?.fontSize ??
                          20) *
                      1.1,
                )
              : null,
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: switch (_step) {
            _Step.input => _buildInput(),
            _Step.importing => _buildBusy(
              _selectedChain == PrivateKeyImportChain.solana
                  ? l10n.privateKeyImportingSolana
                  : l10n.privateKeyImportingEthereum,
            ),
            _Step.done => _buildDone(),
            _Step.error => _buildError(),
          },
        ),
      ),
    );
  }

  Widget _buildInput() {
    final l10n = context.l10n;
    final isSolana = _selectedChain == PrivateKeyImportChain.solana;
    return ListView(
      children: [
        if (widget.groups.isNotEmpty) ...[
          WalletGroupSelector(
            groups: widget.groups,
            selectedId: _selectedGroupId,
            enabled: !_busy,
            onChanged: (value) {
              setState(() {
                _selectedGroupId = value;
                _error = null;
              });
            },
          ),
          const SizedBox(height: 16),
        ],
        Text(
          l10n.privateKeyNetworkLabel,
          style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
        ),
        const SizedBox(height: 8),
        SegmentedButton<PrivateKeyImportChain>(
          showSelectedIcon: false,
          segments: [
            for (final chain in PrivateKeyImportChain.values)
              ButtonSegment(
                value: chain,
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 22,
                      child: chain == _selectedChain
                          ? const Icon(Icons.check, size: 18)
                          : null,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      chain == PrivateKeyImportChain.solana
                          ? 'Solana'
                          : 'Ethereum',
                    ),
                  ],
                ),
              ),
          ],
          selected: {_selectedChain},
          onSelectionChanged: _busy
              ? null
              : (selection) => setState(() {
                  _selectedChain = selection.first;
                  _keyCtrl.clear();
                  _error = null;
                }),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 148,
          child: TextField(
            key: const ValueKey('private-key-input'),
            controller: _keyCtrl,
            obscureText: !_showPrivateKey,
            expands: _showPrivateKey,
            minLines: _showPrivateKey ? null : 1,
            maxLines: _showPrivateKey ? null : 1,
            keyboardType: _showPrivateKey
                ? TextInputType.multiline
                : TextInputType.text,
            textAlignVertical: _showPrivateKey
                ? TextAlignVertical.top
                : TextAlignVertical.center,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            style: const TextStyle(color: TibaneColors.text, fontSize: 16),
            decoration: InputDecoration(
              hintText: isSolana
                  ? l10n.privateKeyFieldHintSolana
                  : l10n.privateKeyFieldHintEthereum,
              hintStyle: const TextStyle(
                color: TibaneColors.textMuted,
                fontSize: 16,
              ),
              contentPadding: const EdgeInsets.fromLTRB(20, 20, 8, 20),
              suffixIconConstraints: const BoxConstraints.tightFor(
                width: 96,
                height: 48,
              ),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const ValueKey('private-key-paste'),
                    tooltip: l10n.wcSessionsPasteTooltip,
                    onPressed: _busy || _pasting ? null : _pastePrivateKey,
                    icon: _pasting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.copy),
                  ),
                  IconButton(
                    tooltip: _showPrivateKey
                        ? l10n.privateKeyHide
                        : l10n.privateKeyShow,
                    onPressed: () =>
                        setState(() => _showPrivateKey = !_showPrivateKey),
                    icon: Icon(
                      _showPrivateKey ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _nameCtrl,
          textInputAction: TextInputAction.next,
          maxLines: 1,
          style: const TextStyle(color: TibaneColors.text, fontSize: 16),
          decoration: InputDecoration(
            hintText: l10n.accountSwitcherAccountName,
            hintStyle: const TextStyle(
              color: TibaneColors.textMuted,
              fontSize: 16,
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _continue,
          style: _primaryStyle,
          child: Text(
            _busy ? l10n.privateKeyChecking : l10n.mnemonicContinueButton,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildBusy(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: TibaneColors.orange),
          const SizedBox(height: 24),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildDone() => PrivateKeyImportConfirmation(
    address: _importedAddress,
    onDone: () => Navigator.of(context).pop(true),
  );

  Widget _buildError() {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.privateKeyImportFailed, style: context.textTheme.titleLarge),
        const SizedBox(height: 12),
        SelectableText(
          _error ?? l10n.sendUnknownError,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const Spacer(),
        FilledButton(
          onPressed: () => setState(() {
            _step = _Step.input;
            _error = null;
          }),
          style: _primaryStyle,
          child: Text(l10n.mnemonicStartOver),
        ),
      ],
    );
  }

  ButtonStyle get _primaryStyle => FilledButton.styleFrom(
    backgroundColor: TibaneColors.orange,
    foregroundColor: TibaneColors.black,
    padding: const EdgeInsets.symmetric(vertical: 14),
  );
}

class PrivateKeyImportConfirmation extends StatelessWidget {
  const PrivateKeyImportConfirmation({
    super.key,
    required this.address,
    required this.onDone,
  });

  final String? address;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = context.textTheme;
    final bodySize = (textTheme.bodyMedium?.fontSize ?? 14) * 1.1;
    final buttonSize = (textTheme.labelLarge?.fontSize ?? 14) * 1.1;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    'assets/app_icon.png',
                    width: 104,
                    height: 104,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                l10n.privateKeyDoneTitle,
                style: textTheme.titleLarge?.copyWith(
                  fontSize: (textTheme.titleLarge?.fontSize ?? 22) * 1.1,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.privateKeyDoneBody,
                style: TextStyle(
                  fontSize: bodySize,
                  color: TibaneColors.textMuted,
                  height: 1.45,
                ),
                textAlign: TextAlign.center,
              ),
              if (address != null) ...[
                const SizedBox(height: 16),
                SelectableText(
                  address!,
                  style: monoStyle(
                    fontSize: 12 * 1.1 * 1.25,
                    color: TibaneColors.text,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 28),
              FilledButton(
                onPressed: onDone,
                style: FilledButton.styleFrom(
                  backgroundColor: TibaneColors.orange,
                  foregroundColor: TibaneColors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  l10n.actionDone,
                  style: TextStyle(fontSize: buttonSize),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
