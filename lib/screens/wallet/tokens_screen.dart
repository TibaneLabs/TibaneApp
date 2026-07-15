import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart'
    show CuratedToken, DiscoveredToken, Network, Token;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/wallet_error_display.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';

/// Token CRUD + discovery for the active network. Lists tokens already
/// registered with libwallet (Token API), shows the curated registry as a
/// quick-add list, and lets the user paste a contract / mint address that
/// runs through tokens.discover() → preview → tokens.create().
class TokensScreen extends StatefulWidget {
  const TokensScreen({super.key});

  @override
  State<TokensScreen> createState() => _TokensScreenState();
}

class _TokensScreenState extends State<TokensScreen> {
  List<Token>? _tokens;
  List<CuratedToken>? _curated;
  Network? _network;
  bool _loading = true;
  String? _error;

  String get _chainKey {
    final n = _network;
    if (n == null) return '';
    // Asset.network format is "<type>.<chainId>" per libwallet docs.
    final family = n.type.name;
    return '$family.${n.chainId}';
  }

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
      final wallet = context.read<WalletService>();
      final client = await wallet.libwallet.ensureClient();
      await wallet.libwallet.refreshCurrentNetwork();
      _network = wallet.libwallet.currentNetwork;
      // Load tokens + curated list in parallel.
      final results = await Future.wait([
        client.tokens.list(),
        if (_chainKey.isNotEmpty)
          client.tokens.listCurated(_chainKey)
        else
          Future.value(<CuratedToken>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _tokens = results[0] as List<Token>;
        _curated = results[1] as List<CuratedToken>;
        _loading = false;
      });
    } catch (e) {
      logError('[Tokens._load] load tokens error: $e');
      if (!mounted) return;
      setState(() {
        _error = WalletError.from(e).message;
        _loading = false;
      });
    }
  }

  Future<void> _addByAddress() async {
    final address = await showDialog<String>(
      context: context,
      builder: (_) => const _AddressEntryDialog(),
    );
    if (address == null || address.isEmpty) return;
    if (_chainKey.isEmpty) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: TibaneColors.orange),
      ),
    );
    try {
      final wallet = context.read<WalletService>();
      final client = await wallet.libwallet.ensureClient();
      final discovered = await client.tokens.discover(
        network: _chainKey,
        address: address,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _DiscoveredPreviewDialog(token: discovered),
      );
      if (confirmed != true) return;
      if (!mounted) return;
      await client.tokens.create(
        name: discovered.name,
        symbol: discovered.symbol,
        address: discovered.address,
        decimals: discovered.decimals,
        network: _chainKey,
        type: discovered.type,
      );
      _load();
      wallet.notifyTokenListChanged();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.tokensAdded(discovered.symbol))),
      );
    } catch (e) {
      logError('[Tokens._addByAddress] discover/create error: $e');
      if (!mounted) return;
      Navigator.of(context).pop();
      showWalletError(context, e);
    }
  }

  Future<void> _addCurated(CuratedToken c) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      final wallet = context.read<WalletService>();
      final client = await wallet.libwallet.ensureClient();
      await client.tokens.create(
        name: c.name,
        symbol: c.symbol,
        address: c.address,
        decimals: c.decimals,
        network: c.chainKey,
        type: c.type,
        logo: c.logoUri.isNotEmpty ? c.logoUri : null,
      );
      _load();
      wallet.notifyTokenListChanged();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l10n.tokensAdded(c.symbol))));
    } catch (e) {
      logError('[Tokens._addCurated] create error: $e');
      if (!mounted) return;
      showWalletError(context, e);
    }
  }

  Future<void> _delete(Token t) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(l10n.tokensRemoveTitle),
        content: Text(
          l10n.tokensRemoveBody(t.symbol.isEmpty ? t.address : t.symbol),
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.actionRemove,
              style: const TextStyle(color: TibaneColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    try {
      final wallet = context.read<WalletService>();
      final client = await wallet.libwallet.ensureClient();
      await client.tokens.delete(t.id);
      _load();
      wallet.notifyTokenListChanged();
    } catch (e) {
      logError('[Tokens._delete] delete error: $e');
      if (!mounted) return;
      showWalletError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: Text(l10n.tokensTitle),
        actions: [
          IconButton(
            tooltip: l10n.actionRefresh,
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: TibaneColors.orange,
        foregroundColor: TibaneColors.black,
        onPressed: _addByAddress,
        icon: const Icon(Icons.add),
        label: Text(l10n.tokensAddByAddress),
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
            // Filter the tracked tokens to the current chain so the picker
            // matches what the user expects to see when looking at this
            // network.
            final tracked = (_tokens ?? const <Token>[])
                .where((t) => _chainKey.isEmpty || t.network == _chainKey)
                .toList();
            final trackedAddrs = tracked.map((t) => t.address).toSet();
            final curated = (_curated ?? const <CuratedToken>[])
                .where((c) => !trackedAddrs.contains(c.address))
                .toList();

            return RefreshIndicator(
              color: TibaneColors.orange,
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
                children: [
                  _SectionLabel(l10n.tokensTrackedSection),
                  const SizedBox(height: 8),
                  if (tracked.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        l10n.tokensNoneTracked,
                        style: monoStyle(
                          fontSize: 12,
                          color: TibaneColors.textMuted,
                        ),
                      ),
                    )
                  else
                    ...tracked.map(
                      (t) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _TokenRow(token: t, onDelete: () => _delete(t)),
                      ),
                    ),
                  if (curated.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _SectionLabel(
                      l10n.tokensCuratedSection(
                        _network?.name ?? l10n.commonThisNetwork,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...curated.map(
                      (c) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _CuratedRow(
                          token: c,
                          onAdd: () => _addCurated(c),
                        ),
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

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
  );
}

class _TokenRow extends StatelessWidget {
  final Token token;
  final VoidCallback onDelete;

  const _TokenRow({required this.token, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final preview = token.address.length > 14
        ? '${token.address.substring(0, 8)}…${token.address.substring(token.address.length - 6)}'
        : token.address;
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          _TokenLogo(url: token.logo, symbol: token.symbol),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  token.symbol.isEmpty ? l10n.tokensNoSymbol : token.symbol,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  token.name,
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
                Text(
                  preview,
                  style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.actionRemove,
            icon: const Icon(Icons.delete_outline, size: 18),
            color: TibaneColors.error,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _CuratedRow extends StatelessWidget {
  final CuratedToken token;
  final VoidCallback onAdd;

  const _CuratedRow({required this.token, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          _TokenLogo(url: token.logoUri, symbol: token.symbol),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      token.symbol,
                      style: const TextStyle(
                        color: TibaneColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (token.tags.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      ...token.tags
                          .take(2)
                          .map(
                            (t) => Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: TibaneColors.cyan.withValues(
                                    alpha: 0.1,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  t,
                                  style: monoStyle(
                                    fontSize: 9,
                                    color: TibaneColors.cyan,
                                  ),
                                ),
                              ),
                            ),
                          ),
                    ],
                  ],
                ),
                Text(
                  token.name,
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: onAdd,
            style: OutlinedButton.styleFrom(
              foregroundColor: TibaneColors.orange,
              side: const BorderSide(color: TibaneColors.orange),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: const Size(0, 0),
            ),
            child: Text(l10n.actionAdd),
          ),
        ],
      ),
    );
  }
}

class _TokenLogo extends StatelessWidget {
  final String? url;
  final String symbol;

  const _TokenLogo({required this.url, required this.symbol});

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u != null && u.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          u,
          width: 36,
          height: 36,
          errorBuilder: (_, __, ___) => _fallback(),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(
      color: TibaneColors.orange.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(8),
    ),
    alignment: Alignment.center,
    child: Text(
      symbol.isEmpty ? '?' : symbol.substring(0, 1).toUpperCase(),
      style: const TextStyle(
        color: TibaneColors.orange,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _AddressEntryDialog extends StatefulWidget {
  const _AddressEntryDialog();

  @override
  State<_AddressEntryDialog> createState() => _AddressEntryDialogState();
}

class _AddressEntryDialogState extends State<_AddressEntryDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      title: Text(l10n.tokensAddDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.tokensAddDialogBody,
            style: const TextStyle(color: TibaneColors.textMuted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autocorrect: false,
            autofocus: true,
            decoration: InputDecoration(labelText: l10n.labelAddress),
            style: monoStyle(fontSize: 13),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.actionCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: Text(
            l10n.tokensDiscover,
            style: const TextStyle(color: TibaneColors.orange),
          ),
        ),
      ],
    );
  }
}

class _DiscoveredPreviewDialog extends StatelessWidget {
  final DiscoveredToken token;

  const _DiscoveredPreviewDialog({required this.token});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      title: Text(l10n.tokensAddThisTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(l10n.labelName, token.name),
          _row(l10n.labelSymbol, token.symbol),
          _row(l10n.labelType, token.type),
          _row(l10n.labelDecimals, token.decimals.toString()),
          if (token.totalSupply != null && token.totalSupply!.isNotEmpty)
            _row(l10n.labelTotalSupply, token.totalSupply!),
          const SizedBox(height: 8),
          Text(
            token.address,
            style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.actionCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            l10n.actionAdd,
            style: const TextStyle(color: TibaneColors.orange),
          ),
        ),
      ],
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 100,
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
}
