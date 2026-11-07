import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/unified_account.dart'
    show UnifiedAccount, abbreviateAccountAddress;
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/network_logos.dart';
import '../../widgets/wallet_error_display.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../utils/context_extensions.dart';
import 'export_private_key_screen.dart';
import 'widgets/account_switcher_view_model.dart';

/// Lists every chain account derived from libwallet wallets on this device.
/// Account creation lives in the account switcher; this screen only manages
/// existing accounts.
class AccountsManagementScreen extends StatefulWidget {
  const AccountsManagementScreen({super.key});

  @override
  State<AccountsManagementScreen> createState() =>
      _AccountsManagementScreenState();
}

class _AccountsManagementScreenState extends State<AccountsManagementScreen> {
  List<UnifiedAccount>? _accounts;
  Map<String, lw.Account> _rawAccountsById = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ws = context.read<WalletService>();
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      // Single source of truth: refresh + read the filtered list from
      // AccountsService (phantom accounts already removed there).
      await ws.refreshAccounts();
      if (!mounted) return;
      setState(() {
        _accounts = ws.accounts.where((account) => account.isInApp).toList();
        _rawAccountsById = {
          for (final account in ws.accountsService.rawAccounts)
            account.id: account,
        };
        _loading = false;
      });
    } catch (e) {
      logError('[AccountsManagement._load] load accounts error: $e');
      if (!mounted) return;
      setState(() {
        _error = walletErrorMessageForContext(context, e);
        _loading = false;
      });
    }
  }

  Future<void> _setActive(UnifiedAccount account) async {
    final ws = context.read<WalletService>();
    final ok = await ws.setCurrentAccount(account);
    if (!mounted) return;
    if (!ok) {
      logError(
        '[AccountsManagement._setActive] switch account failed: '
        '${ws.libwallet.error}',
      );
      showWalletError(
        context,
        ws.libwallet.error ?? 'Could not switch account',
      );
      return;
    }
    // Refresh balances for the new active account so the UI updates.
    ws.refreshBalances();
    _load();
  }

  bool _canExport(UnifiedAccount account) {
    final raw = _rawAccountsById[account.accountId];
    final wallet = context
        .read<WalletService>()
        .accountsService
        .walletsById[account.walletId];
    return account.isInApp &&
        !account.isMainWalletContext &&
        !account.isVirtual &&
        {'solana', 'ethereum', 'evm'}.contains(account.chain) &&
        raw != null &&
        wallet != null &&
        raw.wallet == wallet.id &&
        raw.address == account.address &&
        raw.index == 0 &&
        wallet.threshold == 0 &&
        wallet.keys.length == 1 &&
        wallet.pubkey.isNotEmpty &&
        raw.pubkey == wallet.pubkey;
  }

  Future<void> _openAccount(
    UnifiedAccount account, {
    required bool active,
  }) async {
    final l10n = context.l10n;
    final canExport = _canExport(account);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: TibaneColors.card,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                account.accountName.isNotEmpty
                    ? account.accountName
                    : account.label,
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                abbreviateAccountAddress(account.address),
                style: monoStyle(fontSize: 13, color: TibaneColors.textMuted),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Icon(
                  active
                      ? Icons.check_circle_outline
                      : Icons.account_circle_outlined,
                ),
                title: Text(
                  active ? l10n.accountsActiveBadge : l10n.accountsUseButton,
                ),
                enabled: !active,
                onTap: () => Navigator.pop(sheetContext, 'use'),
              ),
              if (canExport)
                ListTile(
                  key: const Key('account-export-private-key'),
                  leading: const Icon(
                    Icons.key_outlined,
                    color: TibaneColors.orange,
                  ),
                  title: Text(l10n.privateKeyExportTitle),
                  onTap: () => Navigator.pop(sheetContext, 'export'),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'use') {
      await _setActive(account);
    } else if (action == 'export' && _canExport(account)) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ExportPrivateKeyScreen(account: account),
        ),
      );
    }
  }

  Future<void> _remove(UnifiedAccount account) async {
    final rawId = account.accountId;
    if (rawId == null) return;
    final rawAccount = _rawAccountsById[rawId];
    if (rawAccount == null) return;
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(l10n.accountsRemoveTitle),
        content: Text(
          l10n.accountsRemoveBody(
            account.accountName.trim().isNotEmpty
                ? account.accountName
                : account.label,
            abbreviateAccountAddress(account.address),
          ),
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
              l10n.actionRemove,
              style: const TextStyle(color: TibaneColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    try {
      final ws = context.read<WalletService>();
      final walletId = account.walletId;
      if (walletId != null &&
          ws.accountsService.attachedWalletParents.containsKey(walletId)) {
        final removed = await ws.libwallet.removeWallet(walletId);
        if (!removed) {
          throw StateError(ws.libwallet.error ?? 'Could not remove account');
        }
        await ws.accountsService.detachWalletAccount(walletId);
      } else {
        final client = await ws.libwallet.ensureClient();
        final current = await client.accounts.get(rawAccount.id);
        if (current.wallet != rawAccount.wallet) {
          throw StateError('Account no longer belongs to the selected wallet');
        }
        await client.accounts.delete(rawAccount.id);
      }
      _load();
    } catch (e) {
      logError('[AccountsManagement._remove] remove account error: $e');
      if (!mounted) return;
      showWalletError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.accountsTitle)),
      body: SafeArea(
        child: Builder(
          builder: (context) {
            if (_loading) {
              return const Center(
                child: CircularProgressIndicator(color: TibaneColors.orange),
              );
            }
            if (_error != null) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: TibaneColors.textMuted),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            final list = _accounts ?? const [];
            if (list.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.account_circle_outlined,
                        size: 48,
                        color: TibaneColors.textDim,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.accountsEmptyTitle,
                        style: context.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.accountsEmptySubtitle,
                        style: const TextStyle(color: TibaneColors.textMuted),
                      ),
                    ],
                  ),
                ),
              );
            }
            final activeId = context.watch<WalletService>().libwallet.accountId;
            final currentId = context.watch<WalletService>().currentAccount?.id;
            final ws = context.read<WalletService>();
            final groups = buildAccountGroups(
              accounts: list,
              wallets: ws.accountsService.walletsById.values,
              unnamedLabel: l10n.walletsMgmtUnnamed,
              attachedWalletParents: ws.accountsService.attachedWalletParents,
            );
            bool isActive(UnifiedAccount account) =>
                account.id == currentId ||
                (!account.isVirtual && account.accountId == activeId);
            Widget tile(UnifiedAccount account) => _AccountTile(
              account: account,
              active: isActive(account),
              onTap: () => _openAccount(account, active: isActive(account)),
              onRemove: account.isMainWalletContext
                  ? null
                  : () => _remove(account),
            );
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              children: [
                for (final group in groups) ...[
                  _AccountsWalletHeader(group.walletName),
                  const SizedBox(height: 8),
                  for (final account in group.mainAccounts) ...[
                    tile(account),
                    const SizedBox(height: 8),
                  ],
                  if (group.additionalAccounts.isNotEmpty) ...[
                    _AccountsSubHeader(l10n.accountSwitcherAdditionalHeader),
                    const SizedBox(height: 8),
                    for (final account in group.additionalAccounts) ...[
                      tile(account),
                      const SizedBox(height: 8),
                    ],
                  ],
                  const SizedBox(height: 12),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AccountsWalletHeader extends StatelessWidget {
  final String name;

  const _AccountsWalletHeader(this.name);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 4),
      child: Text(
        name,
        style: monoStyle(
          fontSize: 12,
          color: TibaneColors.textMuted,
        ).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _AccountsSubHeader extends StatelessWidget {
  final String text;

  const _AccountsSubHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text,
          style: monoStyle(fontSize: 10, color: TibaneColors.textMuted),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Divider(color: TibaneColors.textMuted.withValues(alpha: 0.22)),
        ),
      ],
    );
  }
}

class _AccountTile extends StatelessWidget {
  final UnifiedAccount account;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _AccountTile({
    required this.account,
    required this.active,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final addr = account.address;
    final canRemove = onRemove != null;
    return TibaneCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          _ManagedAccountIcon(account: account, active: active),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        account.label,
                        style: const TextStyle(
                          color: TibaneColors.text,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (active)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: TibaneColors.cyan.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          l10n.accountsActiveBadge,
                          style: monoStyle(
                            fontSize: 9,
                            color: TibaneColors.cyan,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        abbreviateAccountAddress(addr),
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          fontSize: 11,
                          color: TibaneColors.textMuted,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: addr));
                        context.showSnackBar(
                          SnackBar(
                            content: Text(l10n.addressCopied),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.copy,
                          size: 12,
                          color: TibaneColors.textDim,
                        ),
                      ),
                    ),
                  ],
                ),
                if (!account.isMainWalletContext &&
                    account.walletName.trim().isNotEmpty)
                  Text(
                    l10n.accountsFromWallet(account.walletName),
                    style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                  ),
              ],
            ),
          ),
          if (canRemove)
            IconButton(
              tooltip: l10n.actionRemove,
              icon: const Icon(Icons.delete_outline, size: 18),
              color: TibaneColors.error,
              onPressed: onRemove,
            )
          else
            const SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _ManagedAccountIcon extends StatelessWidget {
  final UnifiedAccount account;
  final bool active;

  const _ManagedAccountIcon({required this.account, required this.active});

  @override
  Widget build(BuildContext context) {
    final asset = orangeNetworkLogoAssetForChain(account.chain);
    Widget fallback() {
      if (account.chain == 'bitcoin' || account.chain == 'bitcoin-cash') {
        final icon = const Icon(
          Icons.currency_bitcoin,
          color: TibaneColors.orange,
          size: 26,
        );
        return account.chain == 'bitcoin-cash'
            ? Transform.rotate(angle: -math.pi / 10, child: icon)
            : icon;
      }
      return const Icon(
        Icons.account_balance_wallet_outlined,
        color: TibaneColors.orange,
        size: 26,
      );
    }

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: TibaneColors.orange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: active
              ? TibaneColors.orange
              : TibaneColors.orange.withValues(alpha: 0.24),
          width: active ? 1.8 : 1,
        ),
      ),
      child: asset == null
          ? fallback()
          : Padding(
              padding: const EdgeInsets.all(9),
              child: Image.asset(
                asset,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => fallback(),
              ),
            ),
    );
  }
}
