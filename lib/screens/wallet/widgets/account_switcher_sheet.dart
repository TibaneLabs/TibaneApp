import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show Network;
import 'package:provider/provider.dart';

import '../../../services/wallet/unified_account.dart';
import '../../../services/wallet_service.dart';
import '../../../theme/tibane_theme.dart';
import '../../../widgets/network_chip.dart';
import '../../../widgets/wallet_error_display.dart';
import '../inapp_export_screen.dart';

/// Open the account switcher (Atonline-parity §4.1/§4.2, Phase 4b-2): the unified
/// list of in-app accounts (across all wallets) + the connected MWA account,
/// with tap-to-switch, add-account (D10), and connect-external (D11).
Future<void> showAccountSwitcher(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: TibaneColors.card,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const AccountSwitcherSheet(),
  );
}

String _short(String addr) => addr.length > 12
    ? '${addr.substring(0, 4)}...${addr.substring(addr.length - 4)}'
    : addr;

/// Switch the active account. When the target is on a different chain than the
/// current network (its address only works on a matching network), first prompt
/// for a compatible network to connect on. Closes the switcher on success.
Future<void> _switchAccount(
  BuildContext context,
  WalletService wallet,
  UnifiedAccount account,
) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final net = wallet.libwallet.currentNetwork;
  String? networkId;
  if (net == null || !accountMatchesNetwork(account, net.type)) {
    List<Network> compatible;
    try {
      compatible = networksForAccount(
        account,
        await wallet.libwallet.listNetworks(),
      );
    } catch (_) {
      compatible = const [];
    }
    if (!context.mounted) return;
    if (compatible.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('No ${chainLabel(account.chain)} network available'),
        ),
      );
      return;
    }
    final picked = await _showNetworkConnectSheet(context, account, compatible);
    if (picked == null || !context.mounted) return; // cancelled
    networkId = picked.id;
  }
  // setCurrentAccount switches the network (picked or auto) BEFORE resolving the
  // account, so the address resolves on the matching chain.
  final ok = await wallet.setCurrentAccount(account, networkId: networkId);
  if (!context.mounted) return;
  if (ok) {
    nav.pop();
  } else {
    showWalletError(context, wallet.libwallet.error ?? 'Could not switch account');
  }
}

/// Bottom sheet listing the networks compatible with [account]'s chain, so the
/// user picks which to connect on (cross-chain account switch). Returns the
/// chosen network, or null if dismissed.
Future<Network?> _showNetworkConnectSheet(
  BuildContext context,
  UnifiedAccount account,
  List<Network> networks,
) {
  return showModalBottomSheet<Network>(
    context: context,
    backgroundColor: TibaneColors.card,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: TibaneColors.textDim,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Select ${chainLabel(account.chain)} network',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'This account connects on a ${chainLabel(account.chain)} network — '
              'pick one to continue.',
              style: const TextStyle(color: TibaneColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            for (final n in networks)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: const Icon(Icons.lan_outlined, color: TibaneColors.orange),
                title: Text(
                  n.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  n.testNet ? '${n.currencySymbol} · testnet' : n.currencySymbol,
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: TibaneColors.textDim,
                  size: 18,
                ),
                onTap: () => Navigator.pop(ctx, n),
              ),
          ],
        ),
      ),
    ),
  );
}

class AccountSwitcherSheet extends StatelessWidget {
  const AccountSwitcherSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<WalletService>(
      builder: (context, wallet, _) {
        final accounts = wallet.accounts;
        final current = wallet.currentAccount;
        final target = addAccountTarget(accounts, current);
        final showMwaConnect = Platform.isAndroid && !wallet.mwa.isConnected;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: TibaneColors.textDim,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Text('Accounts', style: Theme.of(context).textTheme.titleLarge),
                    const Align(
                      alignment: Alignment.centerRight,
                      child: NetworkChip(iconOnly: true),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                for (final a in accounts)
                  _AccountTile(
                    account: a,
                    isCurrent: a.id == current?.id,
                  ),
                if (accounts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No accounts yet',
                      style: TextStyle(color: TibaneColors.textMuted),
                      textAlign: TextAlign.center,
                    ),
                  ),
                const SizedBox(height: 8),
                if (target != null)
                  _ActionTile(
                    icon: Icons.add_circle_outline,
                    label: 'Add account',
                    onTap: () => _showAddAccount(context, wallet, target),
                  ),
                if (showMwaConnect)
                  _ActionTile(
                    icon: Icons.usb,
                    label: 'Connect external (Seed Vault)',
                    onTap: () async {
                      // Capture before the sheet closes so the error can still
                      // be shown on the parent screen.
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      final ok = await wallet.connectMwa();
                      if (!ok) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              wallet.mwa.error ??
                                  'No compatible wallet app is installed.',
                            ),
                          ),
                        );
                      }
                    },
                  ),
                if (current != null) ...[
                  const Divider(height: 24, color: TibaneColors.border),
                  _ActionTile(
                    icon: Icons.copy,
                    label: 'Copy address',
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(
                        ClipboardData(text: current.address),
                      );
                      if (!context.mounted) return;
                      Navigator.pop(context);
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('Address copied'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  if (current.isInApp)
                    _ActionTile(
                      icon: Icons.file_download_outlined,
                      label: 'Export wallet',
                      onTap: () {
                        final nav = Navigator.of(context);
                        Navigator.pop(context);
                        nav.push(
                          MaterialPageRoute(
                            builder: (_) => const InAppExportScreen(),
                          ),
                        );
                      },
                    ),
                  // Disconnect is ONLY for an external (MWA / Seed Vault)
                  // account — it just ends that session; the Seed Vault wallet
                  // stays in its own app. An in-app MPC wallet is lockless and
                  // lives on the device: "disconnecting" it means deleting it
                  // (wallets.delete), which must never be a casual switcher tap.
                  // To remove an in-app wallet, use Wallet details → Remove
                  // (explicit, confirmed).
                  if (current.isMwa)
                    _ActionTile(
                      icon: Icons.logout,
                      label: 'Disconnect external',
                      destructive: true,
                      onTap: () {
                        Navigator.pop(context);
                        wallet.disconnect();
                      },
                    ),
                ],
              ],
            ),
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
    final types = allowedAccountTypesForCurve(target.curve);
    if (types.isEmpty) return;
    final existingCount = wallet.accounts
        .where((a) => a.isInApp && a.walletId == target.walletId)
        .length;
    final nameCtrl = TextEditingController(
      text: suggestAccountName(existingCount),
    );
    var selectedType = types.first;

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: TibaneColors.card,
          title: const Text('Add account'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Account name'),
              ),
              if (types.length > 1) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: selectedType,
                  decoration: const InputDecoration(labelText: 'Chain'),
                  items: [
                    for (final t in types)
                      DropdownMenuItem(value: t, child: Text(chainLabel(t))),
                  ],
                  onChanged: (v) => setState(() => selectedType = v ?? types.first),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'Create',
                style: TextStyle(color: TibaneColors.orange),
              ),
            ),
          ],
        ),
      ),
    );
    if (created != true) return;
    if (!context.mounted) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    final nav = Navigator.of(context);
    final ok = await wallet.addAccount(
      walletId: target.walletId!,
      name: name,
      type: selectedType,
    );
    if (!context.mounted) return;
    if (ok) {
      nav.pop(); // close the switcher; the new account is now current
    } else {
      showWalletError(context, wallet.libwallet.error ?? 'Could not add account');
    }
  }
}

class _AccountTile extends StatelessWidget {
  final UnifiedAccount account;
  final bool isCurrent;

  const _AccountTile({required this.account, required this.isCurrent});

  @override
  Widget build(BuildContext context) {
    final wallet = context.read<WalletService>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isCurrent ? TibaneColors.orange.withValues(alpha: 0.10) : TibaneColors.darker,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: isCurrent ? null : () => _switchAccount(context, wallet, account),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: TibaneColors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    account.isInApp
                        ? Icons.shield_outlined
                        : Icons.account_balance_wallet_outlined,
                    color: TibaneColors.orange,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        account.label,
                        style: const TextStyle(
                          color: TibaneColors.text,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: chainLabel(account.chain),
                              style: monoStyle(
                                fontSize: 11,
                                color: chainColor(account.chain),
                              ).copyWith(fontWeight: FontWeight.w600),
                            ),
                            TextSpan(
                              text: ' · ${_short(account.address)}',
                              style: monoStyle(
                                fontSize: 11,
                                color: TibaneColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (isCurrent)
                  const Icon(Icons.check_circle, color: TibaneColors.orange, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
