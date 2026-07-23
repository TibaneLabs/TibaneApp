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

/// Renders [address] middle-truncated to fill the available width — shows as
/// many leading+trailing characters as fit, ellipsizing only the middle, and
/// the full address when it fits. Falls back to [_short] when space is tight.
class _AddressText extends StatelessWidget {
  final String address;
  final TextStyle style;

  const _AddressText({required this.address, required this.style});

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) => Text(
        _fitAddress(address, style, constraints.maxWidth, scaler),
        style: style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// The widest `head…tail` slice of [address] that fits [maxWidth] in [style]'s
/// (Space Mono, monospace) font. Returns the full address when it fits.
String _fitAddress(
  String address,
  TextStyle style,
  double maxWidth,
  TextScaler scaler,
) {
  if (address.isEmpty || !maxWidth.isFinite || maxWidth <= 0) return address;
  // Monospace: measure a 20-char sample to get the per-character advance
  // (glyph + letterSpacing), then derive how many characters fit.
  final probe = TextPainter(
    text: TextSpan(text: '0' * 20, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final charWidth = probe.width / 20;
  if (charWidth <= 0) return address;
  final fitChars = maxWidth ~/ charWidth;
  if (fitChars >= address.length) return address;
  final maxChars = fitChars - 1; // 1-char safety margin against rounding
  if (maxChars < 8) return _short(address); // too tight for a useful middle
  const ellipsis = '...';
  final keep = maxChars - ellipsis.length;
  final head = (keep + 1) ~/ 2; // bias the head one longer on odd counts
  final tail = keep - head;
  return '${address.substring(0, head)}$ellipsis'
      '${address.substring(address.length - tail)}';
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
                        // One header per wallet (the wallet name), then its main
                        // per-chain contexts, then an inline divider + its
                        // user-created accounts.
                        _SectionTitle(group.walletName),
                        const SizedBox(height: 8),
                        for (final account in group.mainAccounts)
                          _AccountTile(
                            account: account,
                            isCurrent: account.id == current?.id,
                          ),
                        if (group.additionalAccounts.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _SubSectionLabel(
                            l10n.accountSwitcherAdditionalHeader,
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
        wallet.libwallet.error ?? l10n.accountSwitcherAddFailed,
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

/// A lighter inline divider label for the "New accounts" subsection under a
/// wallet's header.
class _SubSectionLabel extends StatelessWidget {
  final String text;

  const _SubSectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text,
          style: monoStyle(
            fontSize: 10,
            color: TibaneColors.textMuted,
          ).copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Divider(
            color: TibaneColors.textMuted.withValues(alpha: 0.22),
            height: 1,
          ),
        ),
      ],
    );
  }
}

/// A switchable account row. Main wallet contexts (a wallet's per-chain receive
/// addresses) render compactly — network logo + address (the logo signals the
/// chain). User-created additional accounts render detailed — avatar + name +
/// chain label + address. Shows a spinner and blocks re-taps while switching.
class _AccountTile extends StatefulWidget {
  final UnifiedAccount account;
  final bool isCurrent;

  const _AccountTile({required this.account, required this.isCurrent});

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
          onTap: (isCurrent || _switching) ? null : _onTap,
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
                _trailing(compact),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _trailing(bool compact) {
    final size = compact ? 19.0 : 20.0;
    if (_switching) {
      return Padding(
        padding: EdgeInsets.only(left: compact ? 8 : 0),
        child: SizedBox(
          width: size,
          height: size,
          child: const CircularProgressIndicator(
            strokeWidth: 2,
            color: TibaneColors.orange,
          ),
        ),
      );
    }
    if (widget.isCurrent) {
      return Padding(
        padding: EdgeInsets.only(left: compact ? 8 : 0),
        child: Icon(Icons.check_circle, color: TibaneColors.orange, size: size),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _leading() {
    final account = widget.account;
    if (account.isMainWalletContext) {
      return _NetworkLogo(
        asset: networkLogoAssetForChain(account.chain),
        chain: account.chain,
      );
    }
    return AccountAvatar(
      asset: account.avatarAsset,
      active: widget.isCurrent,
      fallbackIcon: account.isInApp
          ? Icons.account_circle_outlined
          : Icons.account_balance_wallet_outlined,
    );
  }

  Widget _compactContent() {
    final account = widget.account;
    final address = account.address;
    final style = monoStyle(
      fontSize: 12.5,
      color: _accountMutedText,
    ).copyWith(fontWeight: FontWeight.w600);
    return Row(
      children: [
        Expanded(
          child: address.isEmpty
              ? Text('...', style: style)
              : _AddressText(address: address, style: style),
        ),
        if (address.isNotEmpty) ...[
          const SizedBox(width: 2),
          _CopyAddressButton(account: account),
        ],
      ],
    );
  }

  Widget _detailedContent() {
    final account = widget.account;
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
                          color: _accountMutedText,
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
            child: Icon(Icons.copy, size: 17, color: _accountMutedText),
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
              Text(label, style: TextStyle(color: color, fontSize: 15)),
            ],
          ),
        ),
      ),
    );
  }
}
