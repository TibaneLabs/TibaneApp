import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import 'wallet_welcome_screen.dart';
import 'wallet_dashboard.dart';

/// "Wallet" tab shown on non-Seeker devices. Read-only views (balances,
/// recent activity) render even when the wallet is locked — unlocking is
/// deferred to the moment a signing action is invoked (Send, Swap, etc.).
class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<WalletService>(
      builder: (context, wallet, _) {
        final lw = wallet.libwallet;
        if (!lw.hasWallet) {
          return const WalletWelcomeScreen(showBackButton: false);
        }
        return const WalletDashboard();
      },
    );
  }
}
