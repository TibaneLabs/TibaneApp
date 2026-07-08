import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show Nft, NftAttribute, NftListing;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';

/// NFT collection view for the active account on the active network.
/// Empty for accounts that don't have a valid address on the current
/// chain (e.g. an ed25519-only wallet while a Solana network is active
/// and the dApp queried EVM).
class NftsScreen extends StatefulWidget {
  const NftsScreen({super.key});

  @override
  State<NftsScreen> createState() => _NftsScreenState();
}

class _NftsScreenState extends State<NftsScreen> {
  NftListing? _listing;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final client = await context
          .read<WalletService>()
          .libwallet
          .ensureClient();
      final listing = await client.nfts.list();
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } catch (e) {
      logError('[Nfts._load] load NFTs error: $e');
      if (!mounted) return;
      setState(() {
        _error = WalletError.from(e).message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: const Text('NFTs'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
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
            final list = _listing?.nfts ?? const [];
            if (list.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.collections_outlined,
                        size: 48,
                        color: TibaneColors.textDim,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No NFTs on ${_listing?.network.name ?? "this network"}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Switch networks via the chip in the app bar to look '
                        'on another chain.',
                        style: TextStyle(color: TibaneColors.textMuted),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }
            return RefreshIndicator(
              color: TibaneColors.orange,
              onRefresh: _load,
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.78,
                ),
                itemCount: list.length,
                itemBuilder: (_, i) => _NftCard(
                  nft: list[i],
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => NftDetailScreen(nft: list[i]),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NftCard extends StatelessWidget {
  final Nft nft;
  final VoidCallback onTap;

  const _NftCard({required this.nft, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final imageUrl = nft.imageUrl;
    return Material(
      color: TibaneColors.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: TibaneColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(11),
                  ),
                  child: _NftImage(url: imageUrl),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nft.name.isEmpty ? '#${nft.tokenId}' : nft.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: TibaneColors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (nft.contractName.isNotEmpty)
                      Text(
                        nft.contractName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          fontSize: 10,
                          color: TibaneColors.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NftImage extends StatelessWidget {
  final String? url;

  const _NftImage({required this.url});

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u == null || u.isEmpty) {
      return Container(
        color: TibaneColors.darker,
        child: const Icon(
          Icons.image_not_supported_outlined,
          color: TibaneColors.textDim,
          size: 32,
        ),
      );
    }
    return Image.network(
      u,
      fit: BoxFit.cover,
      loadingBuilder: (_, child, p) => p == null
          ? child
          : Container(
              color: TibaneColors.darker,
              child: const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: TibaneColors.orange,
                  ),
                ),
              ),
            ),
      errorBuilder: (_, __, ___) => Container(
        color: TibaneColors.darker,
        child: const Icon(
          Icons.broken_image_outlined,
          color: TibaneColors.textDim,
          size: 32,
        ),
      ),
    );
  }
}

class NftDetailScreen extends StatelessWidget {
  final Nft nft;

  const NftDetailScreen({super.key, required this.nft});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: Text(nft.name.isEmpty ? '#${nft.tokenId}' : nft.name),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _NftImage(url: nft.imageUrl),
              ),
            ),
            const SizedBox(height: 20),
            if (nft.contractName.isNotEmpty)
              Text(
                nft.contractName.toUpperCase(),
                style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
              ),
            const SizedBox(height: 4),
            Text(
              nft.name.isEmpty ? '#${nft.tokenId}' : nft.name,
              style: const TextStyle(
                color: TibaneColors.text,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (nft.description.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                nft.description,
                style: const TextStyle(
                  color: TibaneColors.textMuted,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 20),
            _kv('Contract', _shorten(nft.contractAddress)),
            if (nft.tokenId.isNotEmpty) _kv('Token ID', nft.tokenId),
            if (nft.network.isNotEmpty) _kv('Network', nft.network),
            if (nft.externalUrl != null && nft.externalUrl!.isNotEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(nft.externalUrl!),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('View externally'),
              ),
            ],
            if (nft.attributes.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'TRAITS',
                style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: nft.attributes.map(_traitChip).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _shorten(String s) =>
      s.length > 14 ? '${s.substring(0, 8)}…${s.substring(s.length - 6)}' : s;

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(
          width: 90,
          child: Text(
            k,
            style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: monoStyle(fontSize: 12, color: TibaneColors.text),
          ),
        ),
      ],
    ),
  );

  Widget _traitChip(NftAttribute a) => TibaneCard(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          a.traitType.toUpperCase(),
          style: monoStyle(fontSize: 9, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 2),
        Text(
          a.value.toString(),
          style: const TextStyle(
            color: TibaneColors.text,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}
