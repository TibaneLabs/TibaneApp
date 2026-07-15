import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/l10n.dart';
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
  String? _type;
  String? _accountId;
  bool _loadingType = true;

  @override
  void initState() {
    super.initState();
    _resolveAccountType();
  }

  /// Look up the active account's chain type so we can pick the right
  /// receive flow. Bitcoin gets a dedicated HD address screen; everything
  /// else falls back to the single-address QR view.
  Future<void> _resolveAccountType() async {
    final wallet = context.read<WalletService>();
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
        _type = acct.type;
        _accountId = acct.id;
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
    if (_type == 'bitcoin' && _accountId != null) {
      return BtcAddressesScreen(accountId: _accountId!);
    }

    final wallet = context.watch<WalletService>();
    final addr = wallet.publicKey ?? '';
    final label = switch (_type) {
      'ethereum' => l10n.receiveAddressLabelEvm,
      'solana' => l10n.receiveAddressLabelSolana,
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
                              fontSize: 12,
                              color: TibaneColors.textMuted,
                            ),
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
