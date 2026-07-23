import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../services/wallet/logical_wallet.dart';
import '../../../services/wallet/unified_account.dart';
import '../../../services/wallet_service.dart';
import '../../../theme/tibane_theme.dart';
import '../../../widgets/network_logos.dart';
import '../../../widgets/wallet_error_display.dart';
import '../../../utils/context_extensions.dart';
import 'account_avatar.dart';
import 'account_switcher_view_model.dart';
import 'add_account_dialog.dart';

/// Open the account switcher (Atonline-parity §4.1/§4.2, Phase 4b-2): the unified
/// list of in-app accounts (across all wallets) + the connected MWA account,
/// with tap-to-switch, add-account (D10), and connect-external (D11).
Future<void> showAccountSwitcher(BuildContext context) {
  unawaited(context.read<WalletService>().refreshAccounts());
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.58),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, _, _) {
      final screenWidth = MediaQuery.sizeOf(ctx).width;
      final width = math.min(screenWidth * 0.75, 333.0);
      return Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: TibaneColors.card,
          child: SizedBox(
            width: width,
            height: double.infinity,
            child: const AccountSwitcherSheet(),
          ),
        ),
      );
    },
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

String _short(String addr) => addr.length > 12
    ? '${addr.substring(0, 4)}...${addr.substring(addr.length - 4)}'
    : addr;

String? _shortDisplayAddress(UnifiedAccount account) {
  if (account.address.isEmpty) return null;
  return _short(account.address);
}

Color _accountTileBaseColor() =>
    Color.lerp(TibaneColors.darker, Colors.black, 0.15)!;

Color _accountTileColor(bool isCurrent) => isCurrent
    ? Color.alphaBlend(
        TibaneColors.orange.withValues(alpha: 0.10),
        _accountTileBaseColor(),
      )
    : _accountTileBaseColor();

Color _accountMutedTextColor() =>
    Color.lerp(TibaneColors.textMuted, TibaneColors.text, 0.50)!;

BorderSide _accountTileBorder(bool isCurrent) => isCurrent
    ? BorderSide(color: TibaneColors.orange.withValues(alpha: 0.74), width: 1.1)
    : BorderSide.none;

Future<void> _copyAccountAddress(
  BuildContext context,
  UnifiedAccount account,
) async {
  if (account.address.isEmpty) return;
  final messenger = context.messenger;
  final copiedLabel = context.l10n.addressCopied;
  await Clipboard.setData(ClipboardData(text: account.address));
  if (!context.mounted) return;
  messenger.showSnackBar(
    SnackBar(content: Text(copiedLabel), duration: const Duration(seconds: 1)),
  );
}

/// Switch the active account. WalletService moves libwallet onto a compatible
/// default network for that account, so users do not need a separate network
/// selection prompt for address families that share the same receiving address.
Future<void> _switchAccount(
  BuildContext context,
  WalletService wallet,
  UnifiedAccount account,
) async {
  final nav = Navigator.of(context);
  final ok = await wallet.setCurrentAccount(account);
  if (!context.mounted) return;
  if (ok) {
    nav.pop();
  } else {
    showWalletError(
      context,
      wallet.libwallet.error ?? 'Could not switch account',
    );
  }
}

class AccountSwitcherSheet extends StatelessWidget {
  const AccountSwitcherSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Consumer<WalletService>(
      builder: (context, wallet, _) {
        final accounts = wallet.accounts;
        final current = wallet.currentAccount;
        final target = addAccountTarget(accounts, current);
        final showMwaConnect = Platform.isAndroid && !wallet.mwa.isConnected;
        final groups = buildAccountGroups(
          accounts: wallet.accounts,
          wallets: wallet.accountsService.walletsById.values,
          unnamedLabel: l10n.walletsMgmtUnnamed,
        );
        final mwaAccounts = accounts.where((account) => account.isMwa).toList();
        return SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.accountsTitle,
                        style: context.textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.actionClose,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                      color: TibaneColors.textMuted,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final group in groups) ...[
                        if (group.mainAccounts.isNotEmpty) ...[
                          _SectionTitle(
                            l10n.accountSwitcherMainWallet(group.walletName),
                          ),
                          const SizedBox(height: 8),
                          for (final account in group.mainAccounts)
                            _AccountTile(
                              account: account,
                              isCurrent: account.id == current?.id,
                            ),
                        ],
                        if (group.additionalAccounts.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          _SectionTitle(
                            l10n.accountSwitcherAdditionalAccounts(
                              group.walletName,
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (final account in group.additionalAccounts)
                            _AccountTile(
                              account: account,
                              isCurrent: account.id == current?.id,
                            ),
                        ],
                        const SizedBox(height: 10),
                      ],
                      if (mwaAccounts.isNotEmpty) ...[
                        _SectionTitle(l10n.accountSwitcherExternalAccounts),
                        const SizedBox(height: 8),
                        for (final account in mwaAccounts)
                          _AccountTile(
                            account: account,
                            isCurrent: account.id == current?.id,
                          ),
                        const SizedBox(height: 10),
                      ],
                      if (accounts.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            l10n.accountSwitcherEmpty,
                            style: const TextStyle(
                              color: TibaneColors.textMuted,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      const SizedBox(height: 8),
                      if (target != null)
                        _ActionTile(
                          icon: Icons.add_circle_outline,
                          label: l10n.accountSwitcherAddAccount,
                          primary: true,
                          onTap: () => _showAddAccount(context, wallet, target),
                        ),
                      if (showMwaConnect)
                        _ActionTile(
                          icon: Icons.usb,
                          label: l10n.accountSwitcherConnectExternal,
                          onTap: () async {
                            final messenger = context.messenger;
                            Navigator.pop(context);
                            final ok = await wallet.connectMwa();
                            if (!ok) {
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    wallet.mwa.error ??
                                        l10n.accountSwitcherNoWalletApp,
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      if (current?.isMwa ?? false)
                        _ActionTile(
                          icon: Icons.logout,
                          label: l10n.accountSwitcherDisconnect,
                          destructive: true,
                          onTap: () {
                            Navigator.pop(context);
                            wallet.disconnect();
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAddAccount(
    BuildContext context,
    WalletService wallet,
    UnifiedAccount target,
  ) async {
    final l10n = context.l10n;
    final groups = buildLogicalWallets(
      wallet.accountsService.walletsById.values,
    ).where((group) => creationChains(group).isNotEmpty).toList();
    if (groups.isEmpty) {
      context.showSnackBar(SnackBar(content: Text(l10n.accountsEmptyTitle)));
      return;
    }

    var selectedAvatarAsset = await wallet.accountsService.suggestAvatarAsset();

    if (!context.mounted) {
      return;
    }
    final result = await showDialog<AddAccountResult>(
      context: context,
      builder: (_) => AddAccountDialog(
        wallet: wallet,
        target: target,
        groups: groups,
        initialAvatarAsset: selectedAvatarAsset,
      ),
    );
    if (result == null) return;
    if (!context.mounted) return;
    final nav = Navigator.of(context);
    final ok = await wallet.addAccount(
      walletId: result.walletId,
      name: result.name,
      type: accountTypeForChain(result.chain),
      preferredChain: result.chain,
      avatarAsset: result.avatarAsset,
    );
    if (!context.mounted) return;
    if (ok) {
      nav.pop(); // close the switcher; the new account is now current
    } else {
      showWalletError(
        context,
        wallet.libwallet.error ?? 'Could not add account',
      );
    }
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
      child: Text(
        text,
        style: monoStyle(
          fontSize: 11,
          color: TibaneColors.textMuted,
        ).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// A switchable account row. Main wallet contexts (a wallet's per-chain
/// receive addresses) render compactly — network logo + address. User-created
/// additional accounts render detailed — avatar + name + chain label + address.
class _AccountTile extends StatelessWidget {
  final UnifiedAccount account;
  final bool isCurrent;

  const _AccountTile({required this.account, required this.isCurrent});

  @override
  Widget build(BuildContext context) {
    final wallet = context.read<WalletService>();
    final compact = account.isMainWalletContext;
    final radius = compact ? 10.0 : 12.0;
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 6 : 8),
      child: Material(
        color: _accountTileColor(isCurrent),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: _accountTileBorder(isCurrent),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap:
              isCurrent ? null : () => _switchAccount(context, wallet, account),
          child: Padding(
            padding: compact
                ? const EdgeInsets.symmetric(horizontal: 12, vertical: 9)
                : const EdgeInsets.all(14),
            child: Row(
              children: [
                _leading(),
                SizedBox(width: compact ? 10 : 14),
                Expanded(
                  child: compact ? _compactContent() : _detailedContent(),
                ),
                if (isCurrent) ...[
                  if (compact) const SizedBox(width: 8),
                  Icon(
                    Icons.check_circle,
                    color: TibaneColors.orange,
                    size: compact ? 19 : 20,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _leading() {
    if (account.isMainWalletContext) {
      return _NetworkLogo(
        asset: networkLogoAssetForChain(account.chain),
        chain: account.chain,
      );
    }
    return AccountAvatar(
      asset: account.avatarAsset,
      active: isCurrent,
      fallbackIcon: account.isInApp
          ? Icons.account_circle_outlined
          : Icons.account_balance_wallet_outlined,
    );
  }

  Widget _compactContent() {
    final displayAddress = _shortDisplayAddress(account);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            displayAddress ?? '...',
            style: monoStyle(
              fontSize: 12.5,
              color: _accountMutedTextColor(),
            ).copyWith(fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (displayAddress != null) ...[
          const SizedBox(width: 2),
          _CopyAddressButton(account: account),
        ],
      ],
    );
  }

  Widget _detailedContent() {
    final displayAddress = _shortDisplayAddress(account);
    final title =
        account.accountName.isNotEmpty ? account.accountName : account.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: TibaneColors.text,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: chainLabel(account.chain),
                      style: monoStyle(
                        fontSize: 11,
                        color: chainColor(account.chain),
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (displayAddress != null)
                      TextSpan(
                        text: ' · $displayAddress',
                        style: monoStyle(
                          fontSize: 11,
                          color: _accountMutedTextColor(),
                        ),
                      ),
                  ],
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (displayAddress != null) ...[
              const SizedBox(width: 2),
              _CopyAddressButton(account: account),
            ],
          ],
        ),
      ],
    );
  }
}

/// Small copy-to-clipboard affordance shared by both tile variants.
class _CopyAddressButton extends StatelessWidget {
  final UnifiedAccount account;

  const _CopyAddressButton({required this.account});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: context.l10n.accountSwitcherCopyAddress,
      child: InkResponse(
        radius: 14,
        onTap: () => _copyAccountAddress(context, account),
        child: SizedBox(
          width: 18,
          height: 18,
          child: Center(
            child:
                Icon(Icons.copy, size: 16.8, color: _accountMutedTextColor()),
          ),
        ),
      ),
    );
  }
}

class _NetworkLogo extends StatelessWidget {
  final String? asset;
  final String chain;

  const _NetworkLogo({required this.asset, required this.chain});

  @override
  Widget build(BuildContext context) {
    const size = 34.0;
    if (asset != null) {
      return ClipOval(
        child: Image.asset(
          asset!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _NetworkLogoFallback(chain: chain),
        ),
      );
    }
    return _NetworkLogoFallback(chain: chain);
  }
}

class _NetworkLogoFallback extends StatelessWidget {
  final String chain;

  const _NetworkLogoFallback({required this.chain});

  @override
  Widget build(BuildContext context) {
    const size = 34.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: chainColor(chain).withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        chainTicker(chain),
        style: monoStyle(
          fontSize: 10,
          color: chainColor(chain),
        ).copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;
  final bool primary;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    if (primary) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Material(
          color: TibaneColors.orange,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: TibaneColors.black, size: 19),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      color: TibaneColors.black,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final color = destructive ? TibaneColors.error : TibaneColors.text;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 14),
              Text(label, style: TextStyle(color: color, fontSize: 15)),
            ],
          ),
        ),
      ),
    );
  }
}
