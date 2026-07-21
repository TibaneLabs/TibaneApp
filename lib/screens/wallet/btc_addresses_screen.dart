import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../utils/context_extensions.dart';

/// Receive / address-management screen for Bitcoin-family accounts. Shows
/// the account's base receive address by default, plus an optional picker to
/// render the same key in an older script format (Legacy / wrapped SegWit)
/// for compat with senders that don't speak bech32. The next clean receive
/// address is available behind an explicit disclosure.
class BtcAddressesScreen extends StatefulWidget {
  final String accountId;
  final String? networkId;
  final String networkName;

  const BtcAddressesScreen({
    super.key,
    required this.accountId,
    this.networkId,
    this.networkName = 'Bitcoin',
  });

  @override
  State<BtcAddressesScreen> createState() => _BtcAddressesScreenState();
}

class _BtcAddressesScreenState extends State<BtcAddressesScreen> {
  lw.NextAddress? _next;
  lw.AddressFormatsResult? _formats;
  bool _loading = true;
  bool _showNextUnused = false;
  String? _error;

  /// When null, the screen renders the base default script address. When set
  /// to a format kind, renders the matching entry from [_formats] — currently
  /// always m/0/0 in that script.
  String? _selectedFormatKind;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final client = await context
          .read<WalletService>()
          .libwallet
          .ensureClient();
      final results = await Future.wait([
        client.accounts.nextAddress(
          widget.accountId,
          network: widget.networkId,
        ),
        client.accounts.addressFormats(
          widget.accountId,
          network: widget.networkId,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _next = results[0] as lw.NextAddress;
        _formats = results[1] as lw.AddressFormatsResult;
        _selectedFormatKind = null; // always start on best format
        _showNextUnused = false;
        _loading = false;
      });
    } catch (e) {
      logError('[BtcAddresses._load] load addresses error: $e');
      if (!mounted) return;
      setState(() {
        _error = WalletError.from(e).message;
        _loading = false;
      });
    }
  }

  bool get _hasSegwitFormats {
    final formats = _formats?.formats ?? const [];
    return formats.any((f) => f.kind.contains('p2wpkh'));
  }

  /// Address currently shown to the user. Null while loading.
  String? get _displayedAddress {
    final sel = _selectedFormatKind;
    if (sel == null) return _defaultAddress ?? _next?.address;
    final formats = _formats?.formats ?? const [];
    for (final f in formats) {
      if (f.kind == sel) return f.address;
    }
    return _defaultAddress ?? _next?.address;
  }

  String? get _defaultAddress {
    final formats = _formats?.formats ?? const [];
    for (final format in formats) {
      if (format.isDefault) return format.address;
    }
    if (formats.isNotEmpty) return formats.first.address;
    return null;
  }

  String? _getDisplayedLabel(AppLocalizations l10n) {
    final sel = _selectedFormatKind;
    if (sel == null) {
      return '$_defaultFormatName (${l10n.btcAddrBest})';
    }
    final formats = _formats?.formats ?? const [];
    for (final f in formats) {
      if (f.kind == sel) return f.name;
    }
    return sel;
  }

  String get _defaultFormatName {
    final formats = _formats?.formats ?? const [];
    for (final format in formats) {
      if (format.isDefault) return format.name;
    }
    return 'Default';
  }

  bool get _isNonSegwitSelected {
    final sel = _selectedFormatKind;
    if (sel == null) return false;
    return sel == 'p2pkh';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: Text(l10n.btcAddrTitleForNetwork(widget.networkName)),
      ),
      body: SafeArea(
        child: Builder(
          builder: (context) {
            if (_loading) {
              return const Center(
                child: CircularProgressIndicator(color: TibaneColors.orange),
              );
            }
            if (_error != null) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: TibaneColors.textMuted),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return RefreshIndicator(
              color: TibaneColors.orange,
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
                children: [
                  if (_displayedAddress != null)
                    _AddressCard(
                      address: _displayedAddress!,
                      label: _getDisplayedLabel(l10n) ?? '',
                    ),
                  if (_selectedFormatKind == null && _next != null) ...[
                    const SizedBox(height: 12),
                    _NextUnusedSection(
                      address: _next!.address,
                      isSameAsCurrent: _next!.address == _displayedAddress,
                      networkName: widget.networkName,
                      expanded: _showNextUnused,
                      onToggle: () =>
                          setState(() => _showNextUnused = !_showNextUnused),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if ((_formats?.formats.length ?? 0) > 1)
                    _FormatPicker(
                      formats: _formats!.formats,
                      selectedKind: _selectedFormatKind,
                      networkName: widget.networkName,
                      onSelect: (kind) =>
                          setState(() => _selectedFormatKind = kind),
                    ),
                  if (_isNonSegwitSelected && _hasSegwitFormats) ...[
                    const SizedBox(height: 12),
                    _WarningCard(
                      text: l10n.btcAddrLegacyWarningForNetwork(
                        widget.networkName,
                      ),
                    ),
                  ],
                  if (_selectedFormatKind != null) ...[
                    const SizedBox(height: 12),
                    _InfoCard(
                      text: l10n.btcAddrAltFormatInfoForNetwork(
                        widget.networkName,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  final String address;
  final String label;

  const _AddressCard({required this.address, required this.label});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TibaneCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: address,
              version: QrVersions.auto,
              size: 200,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            label,
            style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: address));
              if (!context.mounted) return;
              context.showSnackBar(
                SnackBar(
                  content: Text(l10n.addressCopied),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    address,
                    style: monoStyle(fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.copy, size: 14, color: TibaneColors.textDim),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NextUnusedSection extends StatelessWidget {
  final String address;
  final bool isSameAsCurrent;
  final String networkName;
  final bool expanded;
  final VoidCallback onToggle;

  const _NextUnusedSection({
    required this.address,
    required this.isSameAsCurrent,
    required this.networkName,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.btcAddrReuseSafeForNetwork(networkName),
          style: const TextStyle(
            color: TibaneColors.textMuted,
            fontSize: 12,
            height: 1.35,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: onToggle,
          icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          label: Text(l10n.btcAddrShowNextUnused),
          style: ElevatedButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        if (expanded) ...[
          const SizedBox(height: 12),
          _InfoCard(text: l10n.btcAddrNextUnusedInfoForNetwork(networkName)),
          if (isSameAsCurrent) ...[
            const SizedBox(height: 10),
            _InfoCard(text: l10n.btcAddrNextUnusedSameAsCurrent),
          ],
          const SizedBox(height: 10),
          _AddressRowCard(label: l10n.btcAddrNextUnusedLabel, address: address),
        ],
      ],
    );
  }
}

class _AddressRowCard extends StatelessWidget {
  final String label;
  final String address;

  const _AddressRowCard({required this.label, required this.address});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: InkWell(
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: address));
          if (!context.mounted) return;
          context.showSnackBar(
            SnackBar(
              content: Text(l10n.addressCopied),
              duration: const Duration(seconds: 1),
            ),
          );
        },
        borderRadius: BorderRadius.circular(10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    address,
                    style: monoStyle(fontSize: 12, color: TibaneColors.text),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.copy, size: 18, color: TibaneColors.textMuted),
          ],
        ),
      ),
    );
  }
}

class _FormatPicker extends StatelessWidget {
  final List<lw.AddressFormat> formats;
  final String? selectedKind;
  final String networkName;
  final ValueChanged<String?> onSelect;

  const _FormatPicker({
    required this.formats,
    required this.selectedKind,
    required this.networkName,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(l10n.btcAddrFormatLabel),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Chip(
              label: _defaultName,
              selected: selectedKind == null,
              onTap: () => _showFormatInfo(
                context: context,
                kind: null,
                title: l10n.btcAddrFormatRecommendedTitle(_defaultName),
                body: l10n.btcAddrFormatRecommendedBody(
                  networkName,
                  _defaultName,
                ),
              ),
            ),
            for (final f in formats)
              if (!f.isDefault)
                _Chip(
                  label: f.name,
                  selected: selectedKind == f.kind,
                  onTap: () => _showFormatInfo(
                    context: context,
                    kind: f.kind,
                    title: _formatTitle(l10n, f),
                    body: _formatBody(l10n, f),
                  ),
                ),
          ],
        ),
      ],
    );
  }

  Future<void> _showFormatInfo({
    required BuildContext context,
    required String? kind,
    required String title,
    required String body,
  }) async {
    final l10n = context.l10n;
    final selected = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: TibaneColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: TibaneColors.textDim,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(title, style: ctx.textTheme.titleLarge),
              const SizedBox(height: 10),
              Text(
                body,
                style: const TextStyle(
                  color: TibaneColors.textMuted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(l10n.actionCancel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(l10n.btcAddrUseFormat),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == true) onSelect(kind);
  }

  String _formatTitle(AppLocalizations l10n, lw.AddressFormat format) {
    switch (format.kind) {
      case 'p2sh:p2wpkh':
        return l10n.btcAddrFormatWrappedSegwitTitle;
      case 'p2pkh':
        return l10n.btcAddrFormatLegacyTitle;
      default:
        return format.name;
    }
  }

  String _formatBody(AppLocalizations l10n, lw.AddressFormat format) {
    switch (format.kind) {
      case 'p2sh:p2wpkh':
        return l10n.btcAddrFormatWrappedSegwitBodyForNetwork(networkName);
      case 'p2pkh':
        return l10n.btcAddrFormatLegacyBodyForNetwork(networkName);
      default:
        return l10n.btcAddrFormatGenericBodyForNetwork(networkName);
    }
  }

  String get _defaultName {
    for (final format in formats) {
      if (format.isDefault) return format.name;
    }
    return 'Default';
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? TibaneColors.orange.withValues(alpha: 0.15)
              : TibaneColors.darker,
          border: Border.all(
            color: selected ? TibaneColors.orange : TibaneColors.border,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? TibaneColors.orange : TibaneColors.text,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  final String text;

  const _WarningCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TibaneColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TibaneColors.warning.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: TibaneColors.warning,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: TibaneColors.text,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String text;

  const _InfoCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TibaneColors.darker,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TibaneColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline,
            color: TibaneColors.textMuted,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: TibaneColors.textMuted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
  );
}
