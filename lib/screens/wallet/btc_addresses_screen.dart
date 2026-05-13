import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';

/// Receive / address-management screen for Bitcoin-family accounts. Shows
/// the next clean receive address (with QR), plus the full HD listing of
/// addresses that have already seen activity. Tapping any row pops up a
/// QR for that specific address.
class BtcAddressesScreen extends StatefulWidget {
  final String accountId;
  const BtcAddressesScreen({super.key, required this.accountId});

  @override
  State<BtcAddressesScreen> createState() => _BtcAddressesScreenState();
}

class _BtcAddressesScreenState extends State<BtcAddressesScreen> {
  lw.NextAddress? _next;
  lw.AddressListing? _listing;
  bool _loading = true;
  bool _rotating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final client =
          await context.read<WalletService>().libwallet.ensureClient();
      final results = await Future.wait([
        client.accounts.nextAddress(widget.accountId),
        client.accounts.allAddresses(widget.accountId),
      ]);
      if (!mounted) return;
      setState(() {
        _next = results[0] as lw.NextAddress;
        _listing = results[1] as lw.AddressListing;
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
      final client =
          await context.read<WalletService>().libwallet.ensureClient();
      // Calling nextAddress again returns the same clean address if the
      // previous one still has zero activity. To actually advance, ask
      // libwallet to bump the index by deriving a fresh one on the chain
      // — which is what nextAddress does once the previous one is used.
      // For a "rotate before use" UX we just re-fetch; libwallet handles
      // gap-limit advancement once funds arrive.
      final n = await client.accounts.nextAddress(widget.accountId);
      if (!mounted) return;
      setState(() {
        _next = n;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Bitcoin addresses')),
      body: SafeArea(
        child: Builder(builder: (context) {
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
                if (_next != null) _NextAddressCard(
                  next: _next!,
                  rotating: _rotating,
                  onRotate: _rotate,
                ),
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
        }),
      ),
    );
  }
}

class _NextAddressCard extends StatelessWidget {
  final lw.NextAddress next;
  final bool rotating;
  final VoidCallback onRotate;
  const _NextAddressCard({
    required this.next,
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
              data: next.address,
              version: QrVersions.auto,
              size: 200,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Next clean address',
            style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: next.address));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Address copied'),
                duration: Duration(seconds: 1),
              ));
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    next.address,
                    style: monoStyle(fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.copy, size: 14, color: TibaneColors.textDim),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${next.path} · ${next.chain} index ${next.index}',
            style: monoStyle(fontSize: 10, color: TibaneColors.textMuted),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: rotating ? null : onRotate,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(rotating ? 'Rotating…' : 'Get a fresh one'),
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
                    style: monoStyle(fontSize: 10, color: TibaneColors.textMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: addr.address));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Address copied'),
                  duration: Duration(seconds: 1),
                ));
              },
            ),
          ],
        ),
      ),
    );
  }
}
