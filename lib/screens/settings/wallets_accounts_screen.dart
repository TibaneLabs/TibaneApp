import 'package:flutter/material.dart';

import '../../theme/tibane_theme.dart';
import '../contacts/contacts_screen.dart';
import '../settings_screen.dart' show SettingsTile;
import '../wallet/accounts_management_screen.dart';
import '../wallet/device_transfer_receive_screen.dart';
import '../wallet/inapp_export_screen.dart';
import '../wallet/inapp_import_screen.dart';
import '../wallet/networks_screen.dart';
import '../wallet/nfts_screen.dart';
import '../wallet/tokens_screen.dart';
import '../wallet/wallets_management_screen.dart';

/// Sub-screen reached from Settings → "Wallets & Accounts". Groups every
/// option that touches the on-device wallets / accounts / chain state /
/// imports & exports — i.e. the chain-identity surface area.
class WalletsAccountsScreen extends StatelessWidget {
  const WalletsAccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Wallets & Accounts')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              SettingsTile(
                icon: Icons.account_circle_outlined,
                title: 'Manage accounts',
                subtitle: 'Chain accounts derived from your wallets',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AccountsManagementScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.shield_outlined,
                title: 'Manage wallets',
                subtitle: 'Create, back up, or remove on-device wallets',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const WalletsManagementScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.qr_code_scanner,
                title: 'Receive wallet from another device',
                subtitle: 'Scan a QR to move a wallet from your old phone',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DeviceTransferReceiveScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.hub_outlined,
                title: 'Networks',
                subtitle: 'Pick the active blockchain network',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NetworksScreen()),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.token_outlined,
                title: 'Tokens',
                subtitle: 'Add custom tokens or pick from the curated list',
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const TokensScreen())),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.collections_outlined,
                title: 'NFTs',
                subtitle: 'View NFTs held on the active network',
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const NftsScreen())),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.people_outline,
                title: 'Contacts',
                subtitle: 'Saved addresses for sends and swaps',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ContactsScreen()),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.upload_outlined,
                title: 'Import wallet',
                subtitle: 'Seed phrase or encrypted backup file',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const InAppImportScreen()),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.download_outlined,
                title: 'Export in-app wallet',
                subtitle: 'Encrypted backup file (share or save to disk)',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const InAppExportScreen()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
