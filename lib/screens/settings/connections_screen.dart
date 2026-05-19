import 'package:flutter/material.dart';

import '../../theme/tibane_theme.dart';
import '../clawdwallet/agents_screen.dart';
import '../settings_screen.dart' show SettingsTile;
import '../wallet/web3_connections_screen.dart';
import '../walletconnect/walletconnect_sessions_screen.dart';

/// Sub-screen reached from Settings → "Connections". Holds every option
/// for things that talk *to* the wallet from outside it: WalletConnect
/// dApp sessions, in-browser web3 site grants, and ClawdWallet agents.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Connections')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              SettingsTile(
                icon: Icons.link,
                title: 'WalletConnect',
                subtitle: 'Pair and manage dApp sessions',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const WalletConnectSessionsScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.public,
                title: 'Connected sites',
                subtitle: 'Revoke dApp permissions granted in-browser',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const Web3ConnectionsScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.precision_manufacturing_outlined,
                title: 'ClawdWallet agents',
                subtitle: 'Provision and manage agent-controlled MPC wallets',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      backgroundColor: TibaneColors.black,
                      appBar: AppBar(title: const Text('Agent wallets')),
                      body: const SafeArea(child: AgentsScreen()),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
