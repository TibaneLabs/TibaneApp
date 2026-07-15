import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
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
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.settingsConnectionsTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              SettingsTile(
                icon: Icons.link,
                title: l10n.connectionsWalletConnectTitle,
                subtitle: l10n.connectionsWalletConnectSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const WalletConnectSessionsScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.public,
                title: l10n.connectionsConnectedSitesTitle,
                subtitle: l10n.connectionsConnectedSitesSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const Web3ConnectionsScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.precision_manufacturing_outlined,
                title: l10n.connectionsAgentsTitle,
                subtitle: l10n.connectionsAgentsSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      backgroundColor: TibaneColors.black,
                      appBar: AppBar(title: Text(l10n.connectionsAgentWalletsTitle)),
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
