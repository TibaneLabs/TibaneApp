import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show SigningKey;
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../add_hardware_wallet_screen.dart';
import '../../../services/wallet/logical_wallet.dart';
import '../../../services/wallet/unified_account.dart';
import '../../../services/wallet_service.dart';
import '../../../theme/tibane_theme.dart';
import '../../../widgets/network_logos.dart';
import '../../../widgets/wallet_error_display.dart';
import '../../../utils/context_extensions.dart';
import '../create_account_screen.dart';
import '../inapp_import_private_key_screen.dart';
import '../wallet_create_options_screen.dart';
import 'account_switcher_view_model.dart';
import 'sign_sheet.dart';

enum _AddAccountChoice { create, createWallet, importPrivateKey }

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

String? _shortDisplayAddress(UnifiedAccount account) {
  if (account.address.isEmpty) return null;
  return abbreviateAccountAddress(account.address);
}

// Cached tile colors — Color.lerp allocates, and these are constant per theme,
// so compute once instead of on every tile build.
final Color _accountTileBase = Color.lerp(
  TibaneColors.darker,
  Colors.black,
  0.15,
)!;

final Color _accountMutedText = Color.lerp(
  TibaneColors.textMuted,
  TibaneColors.text,
  0.50,
)!;

Color _accountTileColor(bool isCurrent) => isCurrent
    ? Color.alphaBlend(
        TibaneColors.orange.withValues(alpha: 0.10),
        _accountTileBase,
      )
    : _accountTileBase;

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
      wallet.libwallet.error ?? context.l10n.accountSwitcherSwitchFailed,
    );
  }
}

class AccountSwitcherSheet extends StatefulWidget {
  const AccountSwitcherSheet({super.key});

  @override
  State<AccountSwitcherSheet> createState() => _AccountSwitcherSheetState();
}

class _AccountSwitcherSheetState extends State<AccountSwitcherSheet> {
  final Set<String> _expandedGroupIds = {};
  bool _initializedExpansion = false;

  void _initializeExpansion(
    List<AccountSwitcherGroup> groups,
    UnifiedAccount? current,
  ) {
    if (_initializedExpansion || groups.isEmpty) return;
    _initializedExpansion = true;
    AccountSwitcherGroup? selected;
    if (current != null) {
      for (final group in groups) {
        if ([
          ...group.mainAccounts,
          ...group.additionalAccounts,
        ].any((account) => account.id == current.id)) {
          selected = group;
          break;
        }
      }
    }
    _expandedGroupIds.add((selected ?? groups.first).id);
  }

  void _toggleGroup(String id) {
    setState(() {
      if (!_expandedGroupIds.remove(id)) _expandedGroupIds.add(id);
    });
  }

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
          attachedWalletParents: wallet.accountsService.attachedWalletParents,
          walletGroups: wallet.accountsService.walletGroups,
        );
        _initializeExpansion(groups, current);
        // Hardware accounts are libwallet wallets: they list in their wallet
        // group, not here.
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
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          l10n.settingsWalletsAccountsTitle,
                          maxLines: 1,
                          style: context.textTheme.titleLarge,
                        ),
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
                        _WalletSectionHeader(
                          text: group.walletName,
                          expanded: _expandedGroupIds.contains(group.id),
                          onTap: () => _toggleGroup(group.id),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: !_expandedGroupIds.contains(group.id)
                              ? const SizedBox.shrink()
                              : Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const SizedBox(height: 8),
                                    Material(
                                      key: ValueKey(
                                        'account-switcher-group-${group.id}',
                                      ),
                                      color: _accountTileBase,
                                      borderRadius: BorderRadius.circular(10),
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          4,
                                          4,
                                          4,
                                          2,
                                        ),
                                        child: Column(
                                          children: [
                                            for (final account in [
                                              ...group.mainAccounts,
                                              ...group.additionalAccounts,
                                            ])
                                              _AccountTile(
                                                account: account,
                                                grouped: true,
                                                isCurrent:
                                                    account.id == current?.id,
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                        ),
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
                        _PrimaryActionTile(
                          icon: Icons.add_circle_outline,
                          label: l10n.accountSwitcherAddAccount,
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
                      _ActionTile(
                        icon: Icons.usb,
                        label: l10n.hwAddTitle,
                        onTap: () {
                          final navigator = Navigator.of(context);
                          navigator.pop();
                          unawaited(
                            navigator.push(
                              MaterialPageRoute(
                                builder: (_) => const AddHardwareWalletScreen(),
                              ),
                            ),
                          );
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
    final allGroups = buildLogicalWallets(
      wallet.accountsService.walletsById.values,
      attachedWalletParents: wallet.accountsService.attachedWalletParents,
      walletGroups: wallet.accountsService.walletGroups,
    );
    if (allGroups.isEmpty) {
      context.showSnackBar(SnackBar(content: Text(l10n.accountsEmptyTitle)));
      return;
    }
    final groups = allGroups
        .where((group) => creationChains(group).isNotEmpty)
        .toList();
    final choice = await showDialog<_AddAccountChoice>(
      context: context,
      builder: (_) => _AddAccountChoiceDialog(canDerive: groups.isNotEmpty),
    );
    if (choice == null || !context.mounted) return;
    if (choice == _AddAccountChoice.createWallet) {
      final created = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const WalletCreateOptionsScreen()),
      );
      if (created == true && context.mounted) {
        await wallet.refreshAccounts();
        if (context.mounted) Navigator.of(context).pop();
      }
      return;
    }
    if (choice == _AddAccountChoice.importPrivateKey) {
      final imported = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => InAppImportPrivateKeyScreen(
            groups: groups.isEmpty ? const [] : allGroups,
            target: target,
          ),
        ),
      );
      if (imported == true && context.mounted) {
        await wallet.refreshAccounts();
        if (context.mounted) Navigator.of(context).pop();
      }
      return;
    }

    if (groups.isEmpty) {
      context.showSnackBar(SnackBar(content: Text(l10n.accountsEmptyTitle)));
      return;
    }

    final result = await Navigator.of(context).push<AddAccountResult>(
      MaterialPageRoute(
        builder: (_) =>
            CreateAccountScreen(wallet: wallet, target: target, groups: groups),
      ),
    );
    if (result == null) return;
    if (!context.mounted) return;
    List<SigningKey>? keys;
    final targetWallet = wallet.accountsService.walletsById[result.walletId];
    if (targetWallet == null || !supportsDerivedAccounts(targetWallet)) {
      showWalletError(context, l10n.accountSwitcherAddFailed);
      return;
    }
    if (targetWallet.protocol == 'mnemonic') {
      keys = await showSignSheet(
        context,
        wallet: targetWallet,
        normalBiometrics: wallet.libwallet.normalWalletBiometrics,
        readStoreKey: (_, _) async => null,
        title: l10n.accountAddCreateTitle,
        subtitlePurpose: l10n.accountAddCreateTitle,
        actionLabel: l10n.actionConfirm,
      );
      if (keys == null || !context.mounted) return;
    }
    final ok = await wallet.addAccount(
      walletId: result.walletId,
      name: result.name,
      type: accountTypeForChain(result.chain),
      preferredChain: result.chain,
      keys: keys,
    );
    if (!context.mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      showWalletError(
        context,
        wallet.libwallet.error ?? l10n.accountSwitcherAddFailed,
      );
    }
  }
}

class _AddAccountChoiceDialog extends StatelessWidget {
  const _AddAccountChoiceDialog({required this.canDerive});

  final bool canDerive;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      scrollable: true,
      title: Text(l10n.accountSwitcherAddAccount),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ChoiceTile(
            icon: Icons.add_circle_outline,
            title: canDerive
                ? l10n.accountAddCreateTitle
                : l10n.inappCreateButton,
            onTap: () => Navigator.pop(
              context,
              canDerive
                  ? _AddAccountChoice.create
                  : _AddAccountChoice.createWallet,
            ),
          ),
          const SizedBox(height: 10),
          _ChoiceTile(
            icon: Icons.key_outlined,
            title: canDerive
                ? l10n.accountAddImportTitle
                : l10n.accountAddImportAnotherTitle,
            onTap: () =>
                Navigator.pop(context, _AddAccountChoice.importPrivateKey),
          ),
        ],
      ),
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.textDim,
            foregroundColor: TibaneColors.text,
          ),
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.actionCancel),
        ),
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final titleStyle = DefaultTextStyle.of(context).style;
    return Material(
      color: TibaneColors.darker,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(icon, color: TibaneColors.orange, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: titleStyle.copyWith(
                    fontSize: (titleStyle.fontSize ?? 14) * 1.15,
                    color: TibaneColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: TibaneColors.textDim,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WalletSectionHeader extends StatelessWidget {
  final String text;
  final bool expanded;
  final VoidCallback onTap;

  const _WalletSectionHeader({
    required this.text,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final collapsed = !expanded;
    return Material(
      color: collapsed ? TibaneColors.darker : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: collapsed ? TibaneColors.border : Colors.transparent,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: collapsed ? 12 : 2,
            vertical: collapsed ? 12 : 8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  style: monoStyle(
                    fontSize: 16,
                    color: TibaneColors.text,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              AnimatedRotation(
                turns: expanded ? 0 : -0.25,
                duration: const Duration(milliseconds: 180),
                child: const Icon(
                  Icons.keyboard_arrow_down,
                  size: 20,
                  color: TibaneColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

/// A switchable account row with a network title for native contexts, or the
/// user's account name for added accounts, followed by its receive address.
class _AccountTile extends StatefulWidget {
  final UnifiedAccount account;
  final bool isCurrent;
  final bool grouped;

  const _AccountTile({
    required this.account,
    required this.isCurrent,
    this.grouped = false,
  });

  @override
  State<_AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends State<_AccountTile> {
  bool _switching = false;

  Future<void> _onTap() async {
    if (_switching || widget.isCurrent) return;
    setState(() => _switching = true);
    final wallet = context.read<WalletService>();
    await _switchAccount(context, wallet, widget.account);
    // On success _switchAccount pops the sheet (this tile unmounts); on failure
    // it stays put, so clear the spinner.
    if (mounted) setState(() => _switching = false);
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final isCurrent = widget.isCurrent;
    final grouped = widget.grouped;
    final radius = grouped ? 10.0 : 12.0;
    return Padding(
      padding: EdgeInsets.only(bottom: grouped ? (isCurrent ? 6 : 2) : 8),
      child: Material(
        key: ValueKey('account-switcher-row-${account.id}'),
        color: grouped && !isCurrent
            ? Colors.transparent
            : _accountTileColor(isCurrent),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: _accountTileBorder(isCurrent),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: (isCurrent || _switching) ? null : _onTap,
          child: Padding(
            // Grouped rows have an extra 4px inset from their shared background.
            padding: EdgeInsets.symmetric(
              horizontal: grouped ? 12 : 16,
              vertical: 7,
            ),
            child: Row(
              children: [
                _leading(),
                const SizedBox(width: 14),
                Expanded(child: _detailedContent()),
                _trailing(),
                if (account.address.isNotEmpty)
                  _CopyAddressButton(account: account),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _trailing() {
    const size = 20.0;
    if (_switching) {
      return const SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: TibaneColors.orange,
        ),
      );
    }
    if (widget.isCurrent) {
      return const Icon(
        Icons.check_circle,
        color: TibaneColors.orange,
        size: size,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _leading() {
    final account = widget.account;
    return _NetworkLogo(
      asset: orangeNetworkLogoAssetForChain(account.chain),
      chain: account.chain,
    );
  }

  Widget _detailedContent() {
    final account = widget.account;
    final displayAddress = _shortDisplayAddress(account);
    final title = account.isMainWalletContext
        ? chainLabel(account.chain)
        : account.accountName.isNotEmpty
        ? account.accountName
        : account.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: TibaneColors.text,
            fontWeight: FontWeight.w600,
            fontSize: 17.25,
          ),
          maxLines: account.isMainWalletContext ? 2 : 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 1),
        Text(
          displayAddress ?? '...',
          style: monoStyle(
            fontSize: 12.65,
            color: _accountMutedText,
          ).copyWith(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
    // A >=40px hit target (the icon stays small). InkResponse wins the hit test
    // over the surrounding switch InkWell, so a copy tap never triggers a
    // switch.
    return Tooltip(
      message: context.l10n.accountSwitcherCopyAddress,
      child: InkResponse(
        radius: 22,
        onTap: () => _copyAccountAddress(context, account),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: Icon(Icons.copy, size: 19.55, color: _accountMutedText),
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
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: TibaneColors.orange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: TibaneColors.orange.withValues(alpha: 0.24)),
      ),
      child: asset == null
          ? _NetworkLogoFallback(chain: chain)
          : Padding(
              padding: const EdgeInsets.all(7),
              child: Image.asset(
                asset!,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => _NetworkLogoFallback(chain: chain),
              ),
            ),
    );
  }
}

class _NetworkLogoFallback extends StatelessWidget {
  final String chain;

  const _NetworkLogoFallback({required this.chain});

  @override
  Widget build(BuildContext context) {
    if (chain == 'bitcoin') {
      return const Icon(
        Icons.currency_bitcoin,
        size: 20,
        color: TibaneColors.orange,
      );
    }
    if (chain == 'bitcoin-cash') {
      return Transform.rotate(
        angle: -math.pi / 10,
        child: const Icon(
          Icons.currency_bitcoin,
          size: 20,
          color: TibaneColors.orange,
        ),
      );
    }
    return Center(
      child: Text(
        chainTicker(chain),
        style: monoStyle(
          fontSize: 10,
          color: TibaneColors.orange,
        ).copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

/// The prominent orange call-to-action (the "Add account" button).
class _PrimaryActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PrimaryActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
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
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: TibaneColors.black,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A secondary action row (connect external / disconnect).
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
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
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: color, fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
