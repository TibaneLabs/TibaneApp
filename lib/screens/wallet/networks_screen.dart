import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show Network, NetworkType;
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/network_logos.dart';
import '../../widgets/tibane_card.dart';

/// List every libwallet-configured network with the active one highlighted.
/// Tapping a row swaps the current network via `LibwalletBackend.setCurrent
/// Network` and reloads balances downstream.
class NetworksScreen extends StatefulWidget {
  const NetworksScreen({super.key});

  @override
  State<NetworksScreen> createState() => _NetworksScreenState();
}

class _NetworksScreenState extends State<NetworksScreen> {
  List<Network>? _networks;
  bool _loading = true;
  String? _error;
  String? _switchingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final wallet = context.read<WalletService>();
      final client = await wallet.libwallet.ensureClient();
      final list = await client.networks.list();
      await wallet.libwallet.refreshCurrentNetwork();
      if (!mounted) return;
      // Sort: live networks first, then testnets, each by priority desc / name.
      list.sort((a, b) {
        if (a.testNet != b.testNet) return a.testNet ? 1 : -1;
        if (a.priority != b.priority) return b.priority.compareTo(a.priority);
        return a.name.compareTo(b.name);
      });
      setState(() {
        _networks = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _pick(Network n) async {
    final wallet = context.read<WalletService>();
    if (wallet.libwallet.currentNetwork?.id == n.id) return;
    setState(() => _switchingId = n.id);
    final ok = await wallet.libwallet.setCurrentNetwork(n.id);
    if (!mounted) return;
    setState(() => _switchingId = null);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(wallet.libwallet.error ?? 'Switch failed')),
      );
    } else {
      wallet.refreshBalances();
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    final activeId = wallet.libwallet.currentNetwork?.id;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: const Text('Networks'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
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
            final list = _networks ?? const [];
            if (list.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No networks configured.',
                    style: TextStyle(color: TibaneColors.textMuted),
                  ),
                ),
              );
            }
            return RefreshIndicator(
              color: TibaneColors.orange,
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _NetworkRow(
                  net: list[i],
                  active: list[i].id == activeId,
                  switching: _switchingId == list[i].id,
                  onTap: () => _pick(list[i]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NetworkRow extends StatelessWidget {
  final Network net;
  final bool active;
  final bool switching;
  final VoidCallback onTap;

  const _NetworkRow({
    required this.net,
    required this.active,
    required this.switching,
    required this.onTap,
  });

  IconData get _icon {
    switch (net.type) {
      case NetworkType.solana:
        return Icons.flash_on_outlined;
      case NetworkType.evm:
        return Icons.token_outlined;
      case NetworkType.bitcoin:
        return Icons.currency_bitcoin;
      case NetworkType.unknown:
        return Icons.help_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = networkLogoAsset(net);
    final activeTint = active ? TibaneColors.orange : TibaneColors.textMuted;
    return TibaneCard(
      onTap: switching ? null : onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: asset != null
                ? Opacity(
                    // Dim inactive rows so the active network still pops,
                    // mirroring how the Icon variant uses orange vs muted.
                    opacity: active ? 1.0 : 0.55,
                    child: Image.asset(
                      asset,
                      width: 28,
                      height: 28,
                      fit: BoxFit.contain,
                      errorBuilder: (_, e, s) =>
                          Icon(_icon, color: activeTint, size: 22),
                    ),
                  )
                : Icon(_icon, color: activeTint, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        net.name.isEmpty ? '(unnamed)' : net.name,
                        style: const TextStyle(
                          color: TibaneColors.text,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (net.testNet) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: TibaneColors.textDim.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'TEST',
                          style: monoStyle(
                            fontSize: 9,
                            color: TibaneColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${net.type.name} · chainId ${net.chainId} · ${net.currencySymbol}',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
              ],
            ),
          ),
          if (switching)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: TibaneColors.orange,
              ),
            )
          else if (active)
            const Icon(Icons.check, color: TibaneColors.orange, size: 18)
          else
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
