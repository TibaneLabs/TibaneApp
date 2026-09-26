import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show NetworkType;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/unified_account.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import 'btc_addresses_screen.dart';
import '../../utils/context_extensions.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  NetworkType? _networkType;
  String? _accountId;
  String? _networkId;
  String? _networkName;
  bool _loadingType = true;

  @override
  void initState() {
    super.initState();
    _resolveAccountType();
  }

  /// Look up the active network family so we can pick the right receive flow.
  /// Bitcoin is a network context, not a separate app account, so it gets the
  /// dedicated HD address screen when the current network is Bitcoin.
  Future<void> _resolveAccountType() async {
    final wallet = context.read<WalletService>();
    final current = wallet.currentAccount;
    final net =
        await wallet.libwallet.refreshCurrentNetwork() ??
        wallet.libwallet.currentNetwork;
    if (current != null) {
      if (!mounted) return;
      setState(() {
        _networkType = net?.type;
        _accountId = current.accountId;
        _networkId = current.networkId ?? net?.id;
        _networkName =
            current.networkName ?? current.networkSymbol ?? net?.name;
        _loadingType = false;
      });
      return;
    }
    final acctId = wallet.libwallet.accountId;
    if (acctId == null) {
      if (!mounted) return;
      setState(() => _loadingType = false);
      return;
    }
    try {
      final client = await wallet.libwallet.ensureClient();
      final acct = await client.accounts.get(acctId);
      if (!mounted) return;
      setState(() {
        _networkType = net?.type ?? networkTypeForChain(acct.type);
        _accountId = acct.id;
        _networkId = net?.id;
        _networkName = net?.name;
        _loadingType = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingType = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (_loadingType) {
      return Scaffold(
        backgroundColor: TibaneColors.black,
        appBar: AppBar(title: Text(l10n.receiveTitle)),
        body: const Center(
          child: CircularProgressIndicator(color: TibaneColors.orange),
        ),
      );
    }
    if (_networkType == NetworkType.bitcoin && _accountId != null) {
      return BtcAddressesScreen(
        accountId: _accountId!,
        networkId: _networkId,
        networkName: _networkName ?? chainLabel('bitcoin'),
      );
    }

    final wallet = context.watch<WalletService>();
    final activeNetworkType =
        wallet.libwallet.currentNetwork?.type ?? _networkType;
    final activeAccountId = wallet.currentAccount?.accountId ?? _accountId;
    final activeNetworkId =
        wallet.currentAccount?.networkId ??
        wallet.libwallet.currentNetwork?.id ??
        _networkId;
    final activeNetworkName =
        wallet.currentAccount?.networkName ??
        wallet.libwallet.currentNetwork?.name ??
        _networkName ??
        chainLabel(wallet.currentAccount?.chain ?? 'bitcoin');
    if (activeNetworkType == NetworkType.bitcoin && activeAccountId != null) {
      return BtcAddressesScreen(
        accountId: activeAccountId,
        networkId: activeNetworkId,
        networkName: activeNetworkName,
      );
    }
    final addr = wallet.publicKey ?? wallet.currentAccount?.address ?? '';
    final label = switch (activeNetworkType) {
      NetworkType.evm => l10n.receiveAddressLabelEvm,
      NetworkType.solana => l10n.receiveAddressLabelSolana,
      _ => l10n.receiveAddressLabel,
    };
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.receiveTitle)),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: addr,
                    version: QrVersions.auto,
                    size: 220,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  label,
                  style: const TextStyle(color: TibaneColors.textMuted),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: addr));
                    if (!context.mounted) return;
                    context.showSnackBar(
                      SnackBar(
                        content: Text(l10n.addressCopied),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TibaneColors.darker,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            addr,
                            style: monoStyle(
                              fontSize: 13.8,
                              color: TibaneColors.text,
                            ).copyWith(fontWeight: FontWeight.w600),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.copy,
                          size: 16,
                          color: TibaneColors.textDim,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
