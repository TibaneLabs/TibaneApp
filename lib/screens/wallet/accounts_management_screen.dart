import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/unified_account.dart'
    show UnifiedAccount, chainLabel;
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/network_logos.dart';
import '../../widgets/wallet_error_display.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../utils/context_extensions.dart';
import 'widgets/account_avatar.dart';

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
        _error = WalletError.from(e).message;
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
            chainLabel(account.chain),
            rawAccount.path.isNotEmpty ? rawAccount.path : 'index 0',
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
      final client = await context
          .read<WalletService>()
          .libwallet
          .ensureClient();
      await client.accounts.delete(rawAccount.id);
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
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _AccountTile(
                account: list[i],
                active:
                    list[i].id == currentId ||
                    (!list[i].isVirtual && list[i].accountId == activeId),
                onTap: () => _setActive(list[i]),
                onRemove: list[i].isMainWalletContext
                    ? null
                    : () => _remove(list[i]),
              ),
            );
          },
        ),
      ),
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
      onTap: active ? null : onTap,
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
                        '${chainLabel(account.chain)} · $addr',
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
    if (!account.isMainWalletContext) {
      return AccountAvatar(
        asset: account.avatarAsset,
        active: active,
        size: 44,
      );
    }
    final asset = networkLogoAssetForChain(account.chain);
    if (asset == null) {
      return AccountAvatar(
        asset: account.avatarAsset,
        active: active,
        size: 44,
      );
    }
    return SizedBox.square(
      dimension: 44,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipOval(
            child: Image.asset(
              asset,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: active
                    ? TibaneColors.orange
                    : TibaneColors.textDim.withValues(alpha: 0.60),
                width: active ? 1.8 : 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
