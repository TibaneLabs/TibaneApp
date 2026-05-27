import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';

/// Receive / address-management screen for Bitcoin-family accounts. Shows
/// the next clean receive address in the account's default (best) script
/// format by default, plus an optional picker to render the same key in an
/// older script format (Legacy / wrapped SegWit) for compat with senders
/// that don't speak bech32. Always returns to the default format on a
/// fresh visit.
class BtcAddressesScreen extends StatefulWidget {
  final String accountId;

  const BtcAddressesScreen({super.key, required this.accountId});

  @override
  State<BtcAddressesScreen> createState() => _BtcAddressesScreenState();
}

class _BtcAddressesScreenState extends State<BtcAddressesScreen> {
  lw.NextAddress? _next;
  lw.AddressListing? _listing;
  lw.AddressFormatsResult? _formats;
  bool _loading = true;
  bool _rotating = false;
  String? _error;

  /// When null, the screen renders [_next] (the fresh, rotated address in
  /// the default script). When set to a format kind, renders the matching
  /// entry from [_formats] — always m/0/0 in that script.
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
        client.accounts.nextAddress(widget.accountId),
        client.accounts.allAddresses(widget.accountId),
        client.accounts.addressFormats(widget.accountId),
      ]);
      if (!mounted) return;
      setState(() {
        _next = results[0] as lw.NextAddress;
        _listing = results[1] as lw.AddressListing;
        _formats = results[2] as lw.AddressFormatsResult;
        _selectedFormatKind = null; // always start on best format
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _rotate() async {
    if (_rotating) return;
    setState(() => _rotating = true);
    try {
      final client = await context
          .read<WalletService>()
          .libwallet
          .ensureClient();
      // Rotating only makes sense for the default format (rotation is a
      // derivation-path advance, not a script change). Re-fetch + reset
      // the picker so the user lands on the fresh address.
      final n = await client.accounts.nextAddress(widget.accountId);
      if (!mounted) return;
      setState(() {
        _next = n;
        _selectedFormatKind = null;
        _rotating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _rotating = false;
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
    if (sel == null) return _next?.address;
    final formats = _formats?.formats ?? const [];
    for (final f in formats) {
      if (f.kind == sel) return f.address;
    }
    return _next?.address;
  }

  String? get _displayedPath {
    final sel = _selectedFormatKind;
    if (sel == null) return _next?.path;
    final formats = _formats?.formats ?? const [];
    for (final f in formats) {
      if (f.kind == sel) return f.path;
    }
    return _next?.path;
  }

  String? get _displayedLabel {
    final sel = _selectedFormatKind;
    if (sel == null) {
      // Default — pull the human name from formats if available.
      final formats = _formats?.formats ?? const [];
      for (final f in formats) {
        if (f.isDefault) return '${f.name} (best)';
      }
      return 'Default';
    }
    final formats = _formats?.formats ?? const [];
    for (final f in formats) {
      if (f.kind == sel) return f.name;
    }
    return sel;
  }

  bool get _isNonSegwitSelected {
    final sel = _selectedFormatKind;
    if (sel == null) return false;
    return sel == 'p2pkh';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Bitcoin addresses')),
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
                      path: _displayedPath ?? '',
                      label: _displayedLabel ?? '',
                      rotating: _rotating,
                      onRotate: _selectedFormatKind == null ? _rotate : null,
                    ),
                  const SizedBox(height: 16),
                  if ((_formats?.formats.length ?? 0) > 1)
                    _FormatPicker(
                      formats: _formats!.formats,
                      selectedKind: _selectedFormatKind,
                      onSelect: (kind) =>
                          setState(() => _selectedFormatKind = kind),
                    ),
                  if (_isNonSegwitSelected && _hasSegwitFormats) ...[
                    const SizedBox(height: 12),
                    _WarningCard(
                      text:
                          'Receiving on a legacy address will cost more in '
                          'fees when you later spend the funds. Prefer the '
                          'default (SegWit) format unless the sender explicitly '
                          'requires legacy.',
                    ),
                  ],
                  if (_selectedFormatKind != null) ...[
                    const SizedBox(height: 12),
                    _InfoCard(
                      text:
                          'This is the root receive address (m/0/0) rendered '
                          'in an alternate format. Return to the default to '
                          'use a fresh, rotated address.',
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (_listing != null && _listing!.receive.isNotEmpty) ...[
                    _SectionLabel('Receive history (m/0/*)'),
                    const SizedBox(height: 8),
                    ..._listing!.receive.map((a) => _HdRow(addr: a)),
                    const SizedBox(height: 16),
                  ],
                  if (_listing != null && _listing!.change.isNotEmpty) ...[
                    _SectionLabel('Change (m/1/*)'),
                    const SizedBox(height: 8),
                    ..._listing!.change.map((a) => _HdRow(addr: a)),
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
  final String path;
  final String label;
  final bool rotating;
  final VoidCallback? onRotate;

  const _AddressCard({
    required this.address,
    required this.path,
    required this.label,
    required this.rotating,
    required this.onRotate,
  });

  @override
  Widget build(BuildContext context) {
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Address copied'),
                  duration: Duration(seconds: 1),
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
          if (path.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              path,
              style: monoStyle(fontSize: 10, color: TibaneColors.textMuted),
            ),
          ],
          if (onRotate != null) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: rotating ? null : onRotate,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(rotating ? 'Rotating…' : 'Get a fresh one'),
            ),
          ],
        ],
      ),
    );
  }
}

class _FormatPicker extends StatelessWidget {
  final List<lw.AddressFormat> formats;
  final String? selectedKind;
  final ValueChanged<String?> onSelect;

  const _FormatPicker({
    required this.formats,
    required this.selectedKind,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel('Format'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Chip(
              label: 'Default',
              selected: selectedKind == null,
              onTap: () => onSelect(null),
            ),
            for (final f in formats)
              if (!f.isDefault)
                _Chip(
                  label: f.name,
                  selected: selectedKind == f.kind,
                  onTap: () => onSelect(f.kind),
                ),
          ],
        ),
      ],
    );
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

class _HdRow extends StatelessWidget {
  final lw.HdAddress addr;

  const _HdRow({required this.addr});

  @override
  Widget build(BuildContext context) {
    final preview = addr.address.length > 14
        ? '${addr.address.substring(0, 8)}…${addr.address.substring(addr.address.length - 6)}'
        : addr.address;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: TibaneCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(
              addr.clean ? Icons.fiber_new : Icons.history,
              color: addr.clean ? TibaneColors.cyan : TibaneColors.textMuted,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(preview, style: monoStyle(fontSize: 12)),
                  Text(
                    '${addr.path}${addr.clean ? ' · unused' : ''}',
                    style: monoStyle(
                      fontSize: 10,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: addr.address));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Address copied'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
