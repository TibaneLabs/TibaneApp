import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/logical_wallet.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import 'device_transfer_receive_screen.dart';
import 'inapp_create_screen.dart';
import 'share_labels.dart';
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
        _error = WalletError.from(e).message;
        _loading = false;
      });
    }
  }

  Future<void> _addWallet() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const InAppCreateScreen()));
    // Creating a wallet switches the active one (the listener refreshes), but
    // the create -> import -> seed-phrase path adds a wallet WITHOUT changing
    // the active one, so reload explicitly on return to be safe.
    if (mounted) _load();
  }

  Future<void> _openWalletGroup(LogicalWallet group) async {
    if (group.wallets.length == 1) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WalletDetailsScreen(walletId: group.wallets.first.id),
        ),
      );
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WalletGroupDetailsScreen(
            initialWallets: group.wallets,
            activeWalletId:
                (_wallet ?? context.read<WalletService>()).libwallet.walletId,
            withShare: _withShare,
          ),
        ),
      );
    }
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
            final groups = buildLogicalWallets(list);
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
                  (w) => _withShare.contains(w.id),
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
  final Set<String> withShare;

  const WalletGroupDetailsScreen({
    super.key,
    required this.initialWallets,
    required this.activeWalletId,
    required this.withShare,
  });

  @override
  State<WalletGroupDetailsScreen> createState() =>
      _WalletGroupDetailsScreenState();
}

class _WalletGroupDetailsScreenState extends State<WalletGroupDetailsScreen> {
  late final List<lw.Wallet> _wallets = sortWalletsForDisplay(
    widget.initialWallets,
  );

  Future<void> _openTechnicalWallet(lw.Wallet wallet) async {
    final removed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WalletDetailsScreen(walletId: wallet.id),
      ),
    );
    if (!mounted) return;
    if (removed == true) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final group = LogicalWallet(_wallets);
    final networks = _walletGroupNetworks(group, l10n);
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(group.displayName(l10n.walletsMgmtUnnamed))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TibaneCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final network in networks)
                        _WalletNetworkBadge(network: network, active: false),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    networks.map((n) => n.label).join(' · '),
                    style: context.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.walletGroupBody,
                    style: const TextStyle(
                      color: TibaneColors.textMuted,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(
              l10n.walletGroupTechnicalKeysTitle,
              style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
            ),
            const SizedBox(height: 10),
            for (final wallet in _wallets) ...[
              _TechnicalWalletTile(
                wallet: wallet,
                active: wallet.id == widget.activeWalletId,
                usableHere: widget.withShare.contains(wallet.id),
                onTap: () => _openTechnicalWallet(wallet),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
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

class _TechnicalWalletTile extends StatelessWidget {
  final lw.Wallet wallet;
  final bool active;
  final bool usableHere;
  final VoidCallback onTap;

  const _TechnicalWalletTile({
    required this.wallet,
    required this.active,
    required this.usableHere,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final networks = _walletNetworks(wallet, l10n);
    final subkeys = wallet.keys
        .map((k) => shareTypeLabel(k.type, l10n))
        .join(' · ');
    return TibaneCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: networks.length > 1 ? 64 : 32,
            child: Wrap(
              spacing: 4,
              children: [
                for (final network in networks)
                  _WalletNetworkBadge(network: network, active: active),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  networks.map((n) => n.label).join(' · '),
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.walletsMgmtCurve(wallet.curve),
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
                Text(
                  l10n.walletsMgmtShares(subkeys),
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
                if (!usableHere)
                  Text(
                    l10n.walletsMgmtNeeds2fa,
                    style: const TextStyle(
                      fontSize: 11,
                      color: TibaneColors.orange,
                    ),
                  ),
              ],
            ),
          ),
          if (active)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
    final color = chainColor(network.chain);
    final asset = network.asset;
    return Tooltip(
      message: network.label,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(9),
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
