import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show NetworkType;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/hardware_wallet.dart';
import '../../services/wallet/unified_account.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import 'btc_addresses_screen.dart';
import 'widgets/hardware_status.dart';
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
        _networkType = current.isMwa
            ? NetworkType.solana
            : net?.type ?? networkTypeForChain(current.chain);
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
        _networkName = net?.name ?? chainLabel(acct.type);
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
    final activeNetworkType = wallet.currentAccount?.isMwa == true
        ? NetworkType.solana
        : wallet.libwallet.currentNetwork?.type ?? _networkType;
    final activeAccountId = wallet.currentAccount?.accountId ?? _accountId;
    final activeNetworkId =
        wallet.currentAccount?.networkId ??
        wallet.libwallet.currentNetwork?.id ??
        _networkId;
    final activeNetworkName = wallet.currentAccount?.isMwa == true
        ? chainLabel('solana')
        : wallet.currentAccount?.networkName ??
              wallet.libwallet.currentNetwork?.name ??
              _networkName ??
              chainLabel(wallet.currentAccount?.chain ?? 'solana');
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  activeNetworkName,
                  key: const ValueKey('receive-network-title'),
                  style: const TextStyle(
                    color: TibaneColors.orange,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
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
                if (_verifiable(wallet.currentAccount)) ...[
                  const SizedBox(height: 16),
                  _VerifyOnDeviceButton(
                    account: wallet.currentAccount!,
                    address: addr,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A CatCard or Ledger can show the account's address on its own screen.
bool _verifiable(UnifiedAccount? account) {
  final kind = account?.hardware;
  return kind != null &&
      hardwareCanShowAddress(kind) &&
      account!.accountId != null;
}

/// "Verify on device": the device displays the address it derives so the
/// person can check this screen shows the device's own address.
class _VerifyOnDeviceButton extends StatefulWidget {
  const _VerifyOnDeviceButton({required this.account, required this.address});

  final UnifiedAccount account;
  final String address;

  @override
  State<_VerifyOnDeviceButton> createState() => _VerifyOnDeviceButtonState();
}

class _VerifyOnDeviceButtonState extends State<_VerifyOnDeviceButton> {
  bool _busy = false;
  String? _result;
  bool _ok = false;

  Future<void> _verify() async {
    final l10n = context.l10n;
    final hw = context.read<WalletService>().hardware;
    setState(() {
      _busy = true;
      _result = l10n.hwVerifyCompare;
      _ok = false;
    });
    try {
      final shown = await hw.showAddressOnDevice(
        widget.account.hardware!,
        widget.account.accountId!,
        widget.account.chain,
      );
      if (!mounted) return;
      final same = shown.toLowerCase() == widget.address.toLowerCase();
      setState(() {
        _ok = same;
        _result = same ? l10n.hwVerifyOk : l10n.hwVerifyMismatch;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = hardwareErrorText(context, e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _verify,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.verified_user_outlined, size: 18),
          label: Text(context.l10n.hwVerifyOnDevice),
          style: OutlinedButton.styleFrom(
            foregroundColor: TibaneColors.orange,
            side: const BorderSide(color: TibaneColors.orange),
          ),
        ),
        if (_result != null) ...[
          const SizedBox(height: 8),
          Text(
            _result!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _busy || _ok
                  ? TibaneColors.textMuted
                  : TibaneColors.orange,
            ),
          ),
        ],
      ],
    );
  }
}
