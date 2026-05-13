import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show NetworkType;
import 'package:provider/provider.dart';

import '../screens/wallet/networks_screen.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';

/// Compact chip showing the active libwallet network. Tap to open the
/// network picker. Refreshes itself on mount, then relies on [Wallet
/// Service] listener notifications to update.
class NetworkChip extends StatefulWidget {
  const NetworkChip({super.key});

  @override
  State<NetworkChip> createState() => _NetworkChipState();
}

class _NetworkChipState extends State<NetworkChip> {
  bool _kicked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_kicked) return;
    _kicked = true;
    // Fetch once on first build so we have a name to display.
    final wallet = context.read<WalletService>();
    wallet.libwallet.refreshCurrentNetwork();
  }

  Color _accent(NetworkType? t) {
    switch (t) {
      case NetworkType.solana:
        return TibaneColors.cyan;
      case NetworkType.evm:
        return TibaneColors.orange;
      case NetworkType.bitcoin:
        return TibaneColors.cyan;
      default:
        return TibaneColors.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    final net = wallet.libwallet.currentNetwork;
    final color = _accent(net?.type);
    final label = net?.name.isNotEmpty == true ? net!.name : 'Network';
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const NetworksScreen()),
      ),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.15)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.5),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: monoStyle(fontSize: 9, color: color),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 10, color: color),
          ],
        ),
      ),
    );
  }
}
