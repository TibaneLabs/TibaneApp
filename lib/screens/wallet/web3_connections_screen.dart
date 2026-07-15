import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show Web3Connection;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/wallet_error_display.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../utils/context_extensions.dart';

/// Lists every dApp the user has granted EIP-1193 (window.ethereum /
/// window.solana) access to via the in-app browser. Each row exposes a
/// delete button so the user can revoke the connection. Re-granted on
/// the next visit if the dApp asks again.
class Web3ConnectionsScreen extends StatefulWidget {
  const Web3ConnectionsScreen({super.key});

  @override
  State<Web3ConnectionsScreen> createState() => _Web3ConnectionsScreenState();
}

class _Web3ConnectionsScreenState extends State<Web3ConnectionsScreen> {
  List<Web3Connection>? _connections;
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
      final list = await client.web3Connections.list();
      list.sort((a, b) => b.created.compareTo(a.created));
      if (!mounted) return;
      setState(() {
        _connections = list;
        _loading = false;
      });
    } catch (e) {
      logError('[Web3Connections._load] load connections error: $e');
      if (!mounted) return;
      setState(() {
        _error = WalletError.from(e).message;
        _loading = false;
      });
    }
  }

  Future<void> _revoke(Web3Connection c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l10n = ctx.l10n;
        return AlertDialog(
          backgroundColor: TibaneColors.card,
          title: Text(l10n.web3RevokeTitle),
          content: Text(
            l10n.web3RevokeBody(c.host),
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
                l10n.web3RevokeAction,
                style: const TextStyle(color: TibaneColors.error),
              ),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    if (!mounted) return;
    try {
      final client = await context
          .read<WalletService>()
          .libwallet
          .ensureClient();
      await client.web3Connections.delete(c.id);
      _load();
    } catch (e) {
      logError('[Web3Connections._revoke] revoke error: $e');
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
        title: Text(l10n.web3Title),
        actions: [
          IconButton(
            tooltip: l10n.actionRefresh,
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
            final list = _connections ?? const [];
            if (list.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.link_off,
                        size: 48,
                        color: TibaneColors.textDim,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.web3Empty,
                        style: context.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.web3EmptyHint,
                        style: const TextStyle(color: TibaneColors.textMuted),
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
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _ConnectionRow(
                  connection: list[i],
                  onRevoke: () => _revoke(list[i]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ConnectionRow extends StatelessWidget {
  final Web3Connection connection;
  final VoidCallback onRevoke;

  const _ConnectionRow({required this.connection, required this.onRevoke});

  String _formatTime(DateTime t, AppLocalizations l10n) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return l10n.web3TimeJustNow;
    if (diff.inMinutes < 60) return l10n.web3TimeMinutesAgo(diff.inMinutes.toString());
    if (diff.inHours < 24) return l10n.web3TimeHoursAgo(diff.inHours.toString());
    if (diff.inDays < 30) return l10n.web3TimeDaysAgo(diff.inDays.toString());
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: TibaneColors.orange.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.public,
              color: TibaneColors.orange,
              size: 16,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connection.host.isEmpty ? l10n.web3UnknownHost : connection.host,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.web3ConnectedAt(_formatTime(connection.created, l10n)),
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.web3RevokeAction,
            icon: const Icon(Icons.delete_outline, size: 18),
            color: TibaneColors.error,
            onPressed: onRevoke,
          ),
        ],
      ),
    );
  }
}
