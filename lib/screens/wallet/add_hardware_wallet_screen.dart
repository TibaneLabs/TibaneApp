import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/hardware_wallet.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/context_extensions.dart';
import 'widgets/airgap_scan_screen.dart';
import 'widgets/hardware_status.dart';
import 'widgets/ledger_connect_sheet.dart';

/// Add a hardware wallet: a CatCard over USB, a Ledger over USB or Bluetooth,
/// or an air-gapped signer over QR codes. libwallet stores it as a wallet of
/// watch-only accounts; signing goes to the device. Pops true once the new
/// wallet's account is current.
class AddHardwareWalletScreen extends StatefulWidget {
  const AddHardwareWalletScreen({super.key});

  @override
  State<AddHardwareWalletScreen> createState() =>
      _AddHardwareWalletScreenState();
}

class _AddHardwareWalletScreenState extends State<AddHardwareWalletScreen> {
  HardwareKind? _kind;
  bool _busy = false;
  String? _progress;
  String? _error;
  final Set<String> _ledgerApps = {'Solana', 'Ethereum', 'Bitcoin'};

  WalletService get _wallet => context.read<WalletService>();

  Future<void> _run(Future<String?> Function() task, {String? progress}) async {
    setState(() {
      _busy = true;
      _progress = progress;
      _error = null;
    });
    try {
      final walletId = await task();
      if (!mounted || walletId == null) return;
      await _finish(walletId);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e is _Shown ? e.text : hardwareErrorText(context, e),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  /// Make the new wallet's account current (Solana first), or remove the
  /// wallet again when it holds nothing this app can show.
  Future<void> _finish(String walletId) async {
    final wallet = _wallet;
    final l10n = context.l10n;
    await wallet.refreshAccounts();
    final accounts = wallet.accounts
        .where((a) => a.walletId == walletId)
        .toList();
    if (accounts.isEmpty) {
      await wallet.libwallet.removeWallet(walletId);
      await wallet.refreshAccounts();
      if (mounted) setState(() => _error = l10n.hwNoSupportedAccounts);
      return;
    }
    final target =
        accounts.where((a) => a.isSolana).firstOrNull ?? accounts.first;
    await wallet.setCurrentAccount(target);
    if (!mounted) return;
    context.showSnackBar(SnackBar(content: Text(l10n.hwAdded)));
    Navigator.of(context).pop(true);
  }

  Future<void> _addCatCard() => _run(() async {
    final result = await _wallet.hardware.addCatCard();
    return result.wallet.id;
  }, progress: context.l10n.hwCatCardShare);

  Future<void> _addLedger() async {
    final hw = _wallet.hardware;
    final l10n = context.l10n;
    if (!await showLedgerConnectSheet(context, hw.ledger) || !mounted) return;
    // Keep the order Solana, Ethereum, Bitcoin whatever was ticked first.
    final apps = [
      'Solana',
      'Ethereum',
      'Bitcoin',
    ].where(_ledgerApps.contains).toList();
    await _run(() async {
      final r = await hw.addLedger(apps);
      if (r.failed.isNotEmpty && mounted) {
        final why = r.failed.entries
            .map((e) => '${e.key}: ${hardwareErrorText(context, e.value)}')
            .join('\n');
        if (r.walletId == null) throw _Shown(why);
        context.showSnackBar(SnackBar(content: Text(why)));
      }
      return r.walletId;
    }, progress: l10n.hwStatusLedgerReview);
  }

  Future<void> _addAirgap() async {
    final client = await _wallet.libwallet.ensureClient();
    if (!mounted) return;
    final decoderId = await scanAirgapPayload(
      context,
      client: client,
      title: context.l10n.hwAirgapScan,
    );
    if (decoderId == null || !mounted) return;
    await _run(() async {
      try {
        final preview = await client.airgap.parseKeys(decoderId: decoderId);
        final name = preview.device?.trim();
        final result = await client.airgap.importKeys(
          decoderId: decoderId,
          name: name == null || name.isEmpty ? null : name,
        );
        return result.wallet.id;
      } finally {
        unawaited(client.airgap.decoderDelete(decoderId).catchError((_) {}));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopScope(
      canPop: _kind == null && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) setState(() => _kind = null);
      },
      child: Scaffold(
        backgroundColor: TibaneColors.black,
        appBar: AppBar(title: Text(l10n.hwAddTitle)),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: switch (_kind) {
                null => _chooser(context),
                HardwareKind.catcard => _catcardPage(context),
                HardwareKind.ledger => _ledgerPage(context),
                HardwareKind.airgap => _airgapPage(context),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _chooser(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.hwAddBody,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 20),
        _KindTile(
          icon: Icons.usb,
          title: 'CatCard',
          subtitle: l10n.hwCatCardSubtitle,
          onTap: () => setState(() => _kind = HardwareKind.catcard),
        ),
        _KindTile(
          icon: Icons.bluetooth,
          title: 'Ledger',
          subtitle: l10n.hwLedgerSubtitle,
          onTap: () => setState(() => _kind = HardwareKind.ledger),
        ),
        _KindTile(
          icon: Icons.qr_code_2,
          title: l10n.hwAirgapTitle,
          subtitle: l10n.hwAirgapSubtitle,
          onTap: () => setState(() => _kind = HardwareKind.airgap),
        ),
      ],
    );
  }

  Widget _page({
    required String title,
    required List<Widget> body,
    required String action,
    required VoidCallback onAction,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        ...body,
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : onAction,
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            minimumSize: const Size.fromHeight(52),
          ),
          child: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(action),
        ),
        if (_busy && _progress != null) ...[
          const SizedBox(height: 12),
          Text(
            _progress!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: TibaneColors.textMuted),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: TibaneColors.orange, height: 1.4),
          ),
        ],
      ],
    );
  }

  Widget _muted(String text) => Text(
    text,
    style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
  );

  Widget _catcardPage(BuildContext context) {
    final l10n = context.l10n;
    return _page(
      title: 'CatCard',
      body: [
        _muted(l10n.hwCatCardSteps),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: TibaneColors.gold,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(child: _muted(l10n.hwCatCardDevWarning)),
          ],
        ),
      ],
      action: l10n.hwCatCardStart,
      onAction: _addCatCard,
    );
  }

  Widget _ledgerPage(BuildContext context) {
    final l10n = context.l10n;
    return _page(
      title: 'Ledger',
      body: [
        _muted(l10n.hwLedgerSteps),
        const SizedBox(height: 16),
        Text(
          l10n.hwLedgerChains,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final app in const ['Solana', 'Ethereum', 'Bitcoin'])
              FilterChip(
                label: Text(app),
                selected: _ledgerApps.contains(app),
                onSelected: _busy
                    ? null
                    : (on) => setState(() {
                        if (on) {
                          _ledgerApps.add(app);
                        } else if (_ledgerApps.length > 1) {
                          _ledgerApps.remove(app);
                        }
                      }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _muted(l10n.hwLedgerChainsHint),
      ],
      action: l10n.hwLedgerAdd,
      onAction: _addLedger,
    );
  }

  Widget _airgapPage(BuildContext context) {
    final l10n = context.l10n;
    return _page(
      title: l10n.hwAirgapTitle,
      body: [_muted(l10n.hwAirgapSteps)],
      action: l10n.hwAirgapScan,
      onAction: _addAirgap,
    );
  }
}

/// An error whose text is already for a person.
class _Shown implements Exception {
  const _Shown(this.text);
  final String text;
  @override
  String toString() => text;
}

class _KindTile extends StatelessWidget {
  const _KindTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: TibaneColors.card,
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(icon, color: TibaneColors.orange),
        title: Text(title),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
