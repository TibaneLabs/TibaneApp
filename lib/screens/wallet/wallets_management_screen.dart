import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import 'inapp_create_screen.dart';
import 'inapp_import_mnemonic_screen.dart';
import 'share_labels.dart';
import 'wallet_details_screen.dart';

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
      if (!mounted) return;
      setState(() {
        _wallets = list;
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

  Future<void> _addWallet() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const InAppCreateScreen()));
    // _load triggers from WalletService listener on success.
  }

  @override
  Widget build(BuildContext context) {
    final activeId =
        (_wallet ?? context.watch<WalletService>()).libwallet.walletId;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: const Text('Wallets'),
        actions: [
          IconButton(
            tooltip: 'Import mnemonic',
            icon: const Icon(Icons.download_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const InAppImportMnemonicScreen(),
                ),
              );
              // List refreshes via the WalletService listener on success.
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: TibaneColors.orange,
        foregroundColor: TibaneColors.black,
        onPressed: _addWallet,
        icon: const Icon(Icons.add),
        label: const Text('New wallet'),
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
                        'No local wallets yet',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Tap "New wallet" to create one.',
                        style: TextStyle(color: TibaneColors.textMuted),
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
              itemBuilder: (_, i) =>
                  _WalletRow(wallet: list[i], active: list[i].id == activeId),
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

  const _WalletRow({required this.wallet, required this.active});

  @override
  Widget build(BuildContext context) {
    final subkeys = wallet.keys.map((k) => shareTypeLabel(k.type)).join(' · ');
    return TibaneCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WalletDetailsScreen(walletId: wallet.id),
        ),
      ),
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
                  wallet.name.isEmpty ? '(unnamed)' : wallet.name,
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
                    'In use',
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
                  'Curve: ${wallet.curve}',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
                Text(
                  'Shares: $subkeys',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
