import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
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
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.settingsWalletsAccountsTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              SettingsTile(
                icon: Icons.account_circle_outlined,
                title: l10n.walletsAccountsManageAccountsTitle,
                subtitle: l10n.walletsAccountsManageAccountsSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AccountsManagementScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.shield_outlined,
                title: l10n.walletsAccountsManageWalletsTitle,
                subtitle: l10n.walletsAccountsManageWalletsSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const WalletsManagementScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.qr_code_scanner,
                title: l10n.walletsAccountsReceiveFromDeviceTitle,
                subtitle: l10n.walletsAccountsReceiveFromDeviceSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DeviceTransferReceiveScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.hub_outlined,
                title: l10n.networksTitle,
                subtitle: l10n.walletsAccountsNetworksSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NetworksScreen()),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.token_outlined,
                title: l10n.tokensTitle,
                subtitle: l10n.walletsAccountsTokensSubtitle,
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const TokensScreen())),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.collections_outlined,
                title: l10n.walletsAccountsNftsTitle,
                subtitle: l10n.walletsAccountsNftsSubtitle,
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const NftsScreen())),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.people_outline,
                title: l10n.contactsTitle,
                subtitle: l10n.walletsAccountsContactsSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ContactsScreen()),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.upload_outlined,
                title: l10n.walletsAccountsImportWalletTitle,
                subtitle: l10n.walletsAccountsImportWalletSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const InAppImportScreen()),
                ),
              ),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.download_outlined,
                title: l10n.walletsAccountsExportWalletTitle,
                subtitle: l10n.walletsAccountsExportWalletSubtitle,
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
