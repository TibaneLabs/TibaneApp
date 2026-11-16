import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/tibane_theme.dart';
import '../settings_screen.dart' show SettingsTile;
import '../wallet/web3_connections_screen.dart';

class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.settingsConnectionsTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SettingsTile(
              icon: Icons.public,
              title: l10n.web3Title,
              subtitle: l10n.connectionsConnectedSitesSubtitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const Web3ConnectionsScreen(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
