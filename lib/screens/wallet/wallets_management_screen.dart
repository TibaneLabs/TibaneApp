import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
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
      _load();
    }
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
            if (list.isEmpty) {
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
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _WalletRow(
                wallet: list[i],
                active: list[i].id == activeId,
                usableHere: _withShare.contains(list[i].id),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          WalletDetailsScreen(walletId: list[i].id),
                    ),
                  );
                  // Reload on return — a removal or "Use this wallet" may
                  // have changed the list / active wallet.
                  if (mounted) _load();
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WalletRow extends StatelessWidget {
  final lw.Wallet wallet;
  final bool active;
  final bool usableHere;
  final VoidCallback onTap;

  const _WalletRow({
    required this.wallet,
    required this.active,
    required this.usableHere,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final subkeys = wallet.keys.map((k) => shareTypeLabel(k.type, l10n)).join(' · ');
    return TibaneCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                active ? Icons.shield : Icons.shield_outlined,
                color: active ? TibaneColors.orange : TibaneColors.textMuted,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  wallet.name.isEmpty ? l10n.walletsMgmtUnnamed : wallet.name,
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
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.walletsMgmtCurve(wallet.curve),
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
                Text(
                  l10n.walletsMgmtShares(subkeys),
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
          ),
        ],
      ),
    );
  }
}
