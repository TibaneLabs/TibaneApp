import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/logical_wallet.dart';
import '../../services/wallet/unified_account.dart';
import '../../services/wallet/wallet_export_format.dart'
    show isNormalMnemonicWallet;
import '../../services/wallet/hardware_wallet.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/network_logos.dart';
import '../../widgets/wallet_error_display.dart';
import 'widgets/account_switcher_view_model.dart';
import 'inapp_export_screen.dart';
import 'device_transfer_receive_screen.dart';
import 'wallet_welcome_screen.dart';
import 'wallet_details_screen.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../utils/context_extensions.dart';

/// Lists every libwallet wallet on this device. Each row taps into
/// [WalletDetailsScreen]; FAB adds a new wallet via the existing create
/// flow.
class WalletsManagementScreen extends StatefulWidget {
  const WalletsManagementScreen({super.key});

  @override
  State<WalletsManagementScreen> createState() =>
      _WalletsManagementScreenState();
}

class _WalletsManagementScreenState extends State<WalletsManagementScreen> {
  List<lw.Wallet>? _wallets;
  Set<String> _withShare = {};
  bool _loading = true;
  String? _error;
  WalletService? _wallet;
  String? _lastSeenWalletId;
  bool _loadScheduled = false;

  @override
  void initState() {
    super.initState();
    _wallet = context.read<WalletService>();
    _wallet!.addListener(_onChanged);
    _lastSeenWalletId = _wallet!.libwallet.walletId;
    _load();
  }

  @override
  void dispose() {
    _wallet?.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final id = _wallet?.libwallet.walletId;
    if (id != _lastSeenWalletId) {
      _lastSeenWalletId = id;
      _scheduleLoad();
    }
  }

  void _scheduleLoad() {
    if (_loadScheduled) return;
    _loadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadScheduled = false;
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final wallet = _wallet ?? context.read<WalletService>();
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final client = await wallet.libwallet.ensureClient();
      final list = await client.wallets.list();
      // Which of these wallets have a usable device share on THIS device.
      final withShare = <String>{};
      for (final w in list) {
        if (await wallet.libwallet.hasLocalDeviceShare(w.id)) {
          withShare.add(w.id);
        }
      }
      if (!mounted) return;
      setState(() {
        _wallets = list;
        _withShare = withShare;
        _loading = false;
      });
    } catch (e) {
      logError('[WalletsManagement._load] load wallets error: $e');
      if (!mounted) return;
      setState(() {
        _error = walletErrorMessageForContext(context, e);
        _loading = false;
      });
    }
  }

  Future<void> _addWallet() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const WalletWelcomeScreen()));
    // Creating a wallet switches the active one (the listener refreshes), but
    // the create -> import -> seed-phrase path adds a wallet WITHOUT changing
    // the active one, so reload explicitly on return to be safe.
    if (mounted) _load();
  }

  Future<void> _openWalletGroup(LogicalWallet group) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WalletGroupDetailsScreen(
          initialWallets: group.wallets,
          activeWalletId:
              (_wallet ?? context.read<WalletService>()).libwallet.walletId,
          attachedWalletParents: (_wallet ?? context.read<WalletService>())
              .accountsService
              .attachedWalletParents,
        ),
      ),
    );
    if (mounted) _scheduleLoad();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final activeId =
        (_wallet ?? context.watch<WalletService>()).libwallet.walletId;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: Text(l10n.walletsMgmtTitle),
        actions: [
          IconButton(
            tooltip: l10n.walletsMgmtReceiveTooltip,
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const DeviceTransferReceiveScreen(),
                ),
              );
              // A received wallet is added to the list — reload on return.
              if (mounted) _load();
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: TibaneColors.orange,
        foregroundColor: TibaneColors.black,
        onPressed: _addWallet,
        icon: const Icon(Icons.add),
        label: Text(l10n.walletsMgmtNewWallet),
      ),
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
            final list = _wallets ?? const [];
            final groups = buildLogicalWallets(
              list,
              walletGroups: context
                  .read<WalletService>()
                  .accountsService
                  .walletGroups,
              attachedWalletParents: context
                  .read<WalletService>()
                  .accountsService
                  .attachedWalletParents,
            );
            if (groups.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.account_balance_wallet_outlined,
                        size: 48,
                        color: TibaneColors.textDim,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.walletsMgmtEmptyTitle,
                        style: context.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.walletsMgmtEmptySubtitle,
                        style: const TextStyle(color: TibaneColors.textMuted),
                      ),
                    ],
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              itemCount: groups.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _WalletGroupRow(
                group: groups[i],
                active: groups[i].wallets.any((w) => w.id == activeId),
                usableHere: groups[i].wallets.every(
                  (w) =>
                      isNormalMnemonicWallet(w) ||
                      isHardwareWallet(w) ||
                      _withShare.contains(w.id),
                ),
                onTap: () => _openWalletGroup(groups[i]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class WalletGroupDetailsScreen extends StatefulWidget {
  final List<lw.Wallet> initialWallets;
  final String? activeWalletId;
  final Map<String, String> attachedWalletParents;

  const WalletGroupDetailsScreen({
    super.key,
    required this.initialWallets,
    required this.activeWalletId,
    required this.attachedWalletParents,
  });

  @override
  State<WalletGroupDetailsScreen> createState() =>
      _WalletGroupDetailsScreenState();
}

class _WalletGroupDetailsScreenState extends State<WalletGroupDetailsScreen> {
  List<UnifiedAccount> _accounts = const [];
  bool _loading = true;
  bool _busy = false;

  late List<lw.Wallet> _wallets = sortWalletsForDisplay(widget.initialWallets);

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    final service = context.read<WalletService>();
    await service.refreshAccounts();
    if (!mounted) return;
    setState(() {
      _accounts = service.accounts
          .where((a) => a.isInApp && _wallets.any((w) => w.id == a.walletId))
          .toList();
      _loading = false;
    });
  }

  Future<void> _rename() async {
    final name = await showRenameWalletDialog(
      context,
      LogicalWallet(_wallets).displayName(context.l10n.walletsMgmtUnnamed),
    );
    if (name == null || !mounted) return;
    final service = context.read<WalletService>();
    setState(() => _busy = true);
    try {
      for (final wallet in _wallets) {
        if (!await service.libwallet.renameWallet(wallet.id, name)) {
          throw StateError(service.libwallet.error ?? 'Rename failed');
        }
      }
    } catch (error) {
      if (mounted) showWalletError(context, error);
    } finally {
      try {
        final client = await service.libwallet.ensureClient();
        final ids = _wallets.map((w) => w.id).toSet();
        final updated = (await client.wallets.list())
            .where((w) => ids.contains(w.id))
            .toList();
        if (mounted && updated.isNotEmpty) {
          setState(() => _wallets = sortWalletsForDisplay(updated));
        }
        if (mounted) await _loadAccounts();
      } catch (error) {
        if (mounted) showWalletError(context, error);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _remove() async {
    final confirmed = await showRemoveWalletDialog(context);
    if (confirmed != true || !mounted) return;
    final service = context.read<WalletService>();
    setState(() => _busy = true);
    final ids = _wallets.map((wallet) => wallet.id).toSet();
    final removed = await service.libwallet.removeWallets(ids);
    await service.refreshAccounts();
    if (!mounted) return;
    if (removed) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _busy = false);
      showWalletError(
        context,
        service.libwallet.error ?? context.l10n.walletDetailsRemoveFailed,
      );
    }
  }

  Future<void> _backup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InAppExportScreen(
          walletIds: _wallets.map((w) => w.id).toSet(),
          walletName: LogicalWallet(
            _wallets,
          ).displayName(context.l10n.walletsMgmtUnnamed),
        ),
      ),
    );
    if (mounted) {
      await _loadAccounts();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final group = LogicalWallet(_wallets);
    final main =
        _accounts
            .where(
              (a) =>
                  a.isMainWalletContext &&
                  !widget.attachedWalletParents.containsKey(a.walletId),
            )
            .toList()
          ..sort(compareAccountsForSwitcher);
    final added = _accounts.where((a) => !main.contains(a)).toList()
      ..sort(compareAccountsForSwitcher);
    final canBackup =
        _wallets.isNotEmpty &&
        _wallets.every((wallet) => wallet.keys.any((key) => key.isPassword));
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(group.displayName(l10n.walletsMgmtUnnamed))),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    l10n.walletGroupContentsTitle,
                    style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                  ),
                  const SizedBox(height: 10),
                  if (main.isNotEmpty)
                    TibaneCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 4,
                      ),
                      child: Column(
                        children: [
                          for (final account in main)
                            _WalletAccountRow(account: account),
                        ],
                      ),
                    ),
                  if (added.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      l10n.accountSwitcherAdditionalHeader,
                      style: monoStyle(
                        fontSize: 13.2,
                        color: TibaneColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final account in added) ...[
                      TibaneCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 4,
                        ),
                        child: _WalletAccountRow(account: account),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _rename,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: Text(l10n.walletDetailsRenameTitle),
                  ),
                  const SizedBox(height: 8),
                  Tooltip(
                    message: canBackup
                        ? l10n.walletDetailsExportButton
                        : l10n.walletGroupBackupUnavailable,
                    child: OutlinedButton.icon(
                      onPressed: _busy || !canBackup ? null : _backup,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: Text(l10n.walletDetailsExportButton),
                    ),
                  ),
                  if (!canBackup)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        l10n.walletGroupBackupUnavailable,
                        style: const TextStyle(
                          fontSize: 12,
                          color: TibaneColors.orange,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _remove,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: TibaneColors.error,
                    ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text(l10n.actionRemove),
                  ),
                ],
              ),
      ),
    );
  }
}

class _WalletAccountRow extends StatelessWidget {
  const _WalletAccountRow({required this.account});
  final UnifiedAccount account;
  @override
  Widget build(BuildContext context) {
    final asset = orangeNetworkLogoAssetForChain(account.chain);
    return Padding(
      key: ValueKey('wallet-account-${account.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          _WalletNetworkBadge(
            network: _WalletNetwork(
              label: chainLabel(account.chain),
              chain: account.chain,
              asset: asset,
              fallbackIcon: Icons.currency_bitcoin,
            ),
            active: false,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  account.accountName.isNotEmpty
                      ? account.accountName
                      : chainLabel(account.chain),
                  style: const TextStyle(
                    fontSize: 17.25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  abbreviateAccountAddress(account.address),
                  style: monoStyle(
                    fontSize: 12.65,
                    color: TibaneColors.textMuted,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WalletGroupRow extends StatelessWidget {
  final LogicalWallet group;
  final bool active;
  final bool usableHere;
  final VoidCallback onTap;

  const _WalletGroupRow({
    required this.group,
    required this.active,
    required this.usableHere,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final networks = _walletGroupNetworks(group, l10n);
    return TibaneCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  group.displayName(l10n.walletsMgmtUnnamed),
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 15,
                  ),
                ),
              ),
              if (active)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: TibaneColors.cyan.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    l10n.walletsMgmtInUseBadge,
                    style: monoStyle(fontSize: 10, color: TibaneColors.cyan),
                  ),
                ),
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right,
                color: TibaneColors.textDim,
                size: 18,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${l10n.labelNetwork}: '
                '${networks.map((n) => n.label).join(' · ')}',
                style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
              ),
              if (!usableHere)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    l10n.walletsMgmtNeeds2fa,
                    style: const TextStyle(
                      fontSize: 11,
                      color: TibaneColors.orange,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WalletNetwork {
  final String label;
  final String chain;
  final String? asset;
  final IconData fallbackIcon;

  const _WalletNetwork({
    required this.label,
    required this.chain,
    required this.asset,
    required this.fallbackIcon,
  });
}

List<_WalletNetwork> _walletNetworks(lw.Wallet wallet, AppLocalizations l10n) {
  switch (wallet.curve) {
    case 'ed25519':
      return [
        _WalletNetwork(
          label: l10n.sendNetworkSolana,
          chain: 'solana',
          asset: 'assets/icons/solana-sol-logo-orange-network.png',
          fallbackIcon: Icons.blur_on,
        ),
      ];
    case 'secp256k1':
      return [
        _WalletNetwork(
          label: l10n.sendNetworkEthereum,
          chain: 'ethereum',
          asset: 'assets/icons/ethereum-eth-logo-orange-network.png',
          fallbackIcon: Icons.account_tree_outlined,
        ),
        if (wallet.keys.length != 1 || isNormalMnemonicWallet(wallet))
          _WalletNetwork(
            label: l10n.sendNetworkBitcoin,
            chain: 'bitcoin',
            asset: null,
            fallbackIcon: Icons.currency_bitcoin,
          ),
      ];
    default:
      return [
        _WalletNetwork(
          label: wallet.curve,
          chain: '',
          asset: null,
          fallbackIcon: Icons.lan_outlined,
        ),
      ];
  }
}

List<_WalletNetwork> _walletGroupNetworks(
  LogicalWallet group,
  AppLocalizations l10n,
) {
  final out = <_WalletNetwork>[];
  final seen = <String>{};
  for (final wallet in group.wallets) {
    for (final network in _walletNetworks(wallet, l10n)) {
      if (seen.add(network.chain)) out.add(network);
    }
  }
  return out;
}

class _WalletNetworkBadge extends StatelessWidget {
  final _WalletNetwork network;
  final bool active;

  const _WalletNetworkBadge({required this.network, required this.active});

  @override
  Widget build(BuildContext context) {
    const color = TibaneColors.orange;
    final asset = network.asset;
    return Tooltip(
      message: network.label,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: active
              ? Border.all(color: TibaneColors.orange.withValues(alpha: 0.55))
              : Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: asset == null
            ? Icon(network.fallbackIcon, size: 17, color: color)
            : Padding(
                padding: const EdgeInsets.all(6),
                child: Image.asset(asset, fit: BoxFit.contain),
              ),
      ),
    );
  }
}
