import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/connected_dapps.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/context_extensions.dart';
import '../../utils/wallet_error.dart';
import '../../widgets/tibane_card.dart';

class Web3ConnectionsScreen extends StatefulWidget {
  const Web3ConnectionsScreen({super.key});

  @override
  State<Web3ConnectionsScreen> createState() => _Web3ConnectionsScreenState();
}

class _Web3ConnectionsScreenState extends State<Web3ConnectionsScreen> {
  List<ConnectedDapp> _connections = const [];
  String? _walletId;
  bool _loading = true;
  bool _revoking = false;
  String? _error;
  int _revision = 0;

  String? _selectedWalletId(WalletService wallet) {
    final account = wallet.currentAccount;
    return account?.isInApp == true ? account?.walletId : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final walletId = _selectedWalletId(context.watch<WalletService>());
    if (_revision == 0 || walletId != _walletId) {
      _walletId = walletId;
      _connections = const [];
      _load();
    }
  }

  Future<void> _load({bool revokeFailed = false}) async {
    final revision = ++_revision;
    final wallet = context.read<WalletService>();
    final walletId = _walletId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = walletId == null
          ? <ConnectedDapp>[]
          : await listConnectedDapps(
              await wallet.libwallet.ensureClient(),
              connectedAccountsFor(wallet, walletId),
            );
      if (!mounted || revision != _revision) return;
      setState(() => _connections = list);
    } catch (e) {
      if (!mounted || revision != _revision) return;
      setState(() => _error = walletErrorMessageForContext(context, e));
    } finally {
      if (mounted && revision == _revision) {
        setState(() {
          _loading = false;
          if (revokeFailed) _error ??= context.l10n.web3RevokeFailed;
        });
      }
    }
  }

  Future<void> _revoke({ConnectedDapp? single}) async {
    final walletId = _walletId;
    if (walletId == null || _loading || _revoking) return;
    final wallet = context.read<WalletService>();
    final l10n = context.l10n;
    final revision = _revision;
    final reviewed = {
      for (final entry in single == null ? _connections : [single])
        (entry.isSession, entry.id),
    };
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(single == null ? l10n.web3RevokeAll : l10n.web3RevokeTitle),
        content: Text(
          single == null
              ? l10n.web3RevokeAllBody
              : single.isSession
              ? l10n.web3DisconnectSessionBody
              : l10n.web3RevokeBody(single.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: TibaneColors.orange,
              foregroundColor: TibaneColors.black,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.actionConfirm),
          ),
        ],
      ),
    );
    bool isCurrent() =>
        mounted &&
        _revision == revision &&
        _selectedWalletId(wallet) == walletId;
    if (approved != true || !isCurrent() || _revoking) return;
    setState(() => _revoking = true);
    var failed = false;
    try {
      final client = await wallet.libwallet.ensureClient();
      if (!isCurrent()) return;
      final list = await listConnectedDapps(
        client,
        connectedAccountsFor(wallet, walletId),
      );
      for (final entry in list) {
        if (!isCurrent()) break;
        if (!reviewed.contains((entry.isSession, entry.id))) {
          continue;
        }
        try {
          await entry.revoke(client);
        } catch (_) {
          failed = true;
        }
      }
    } catch (_) {
      failed = true;
    } finally {
      if (mounted) {
        setState(() => _revoking = false);
        if (isCurrent()) await _load(revokeFailed: failed);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final busy = _loading || _revoking;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: Text(l10n.web3Title, maxLines: 2),
        actions: [
          IconButton(
            tooltip: l10n.actionRefresh,
            onPressed: busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: TibaneColors.orange),
              )
            : RefreshIndicator(
                color: TibaneColors.orange,
                onRefresh: () async {
                  if (!busy) await _load();
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: TibaneColors.error),
                        ),
                      )
                    else if (_connections.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            const Icon(
                              Icons.link_off,
                              size: 48,
                              color: TibaneColors.textDim,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _walletId == null
                                  ? l10n.web3SelectWallet
                                  : l10n.web3Empty,
                              style: context.textTheme.titleMedium,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    for (final connection in _connections)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ConnectionRow(
                          connection: connection,
                          onRevoke: busy
                              ? null
                              : () => _revoke(single: connection),
                        ),
                      ),
                  ],
                ),
              ),
      ),
      bottomNavigationBar: _connections.isEmpty && !_revoking
          ? null
          : SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: FilledButton(
                onPressed: busy ? null : () => _revoke(),
                style: FilledButton.styleFrom(
                  backgroundColor: TibaneColors.orange,
                  foregroundColor: TibaneColors.black,
                  minimumSize: const Size(0, 48),
                ),
                child: _revoking
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.web3RevokeAll),
              ),
            ),
    );
  }
}

class _ConnectionRow extends StatelessWidget {
  final ConnectedDapp connection;
  final VoidCallback? onRevoke;

  const _ConnectionRow({required this.connection, required this.onRevoke});

  String _formatTime(DateTime t, AppLocalizations l10n) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return l10n.web3TimeJustNow;
    if (diff.inMinutes < 60) {
      return l10n.web3TimeMinutesAgo(diff.inMinutes.toString());
    }
    if (diff.inHours < 24) {
      return l10n.web3TimeHoursAgo(diff.inHours.toString());
    }
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
            child: Icon(
              connection.isSession ? Icons.link : Icons.public,
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
                  connection.name.isEmpty
                      ? l10n.web3UnknownHost
                      : connection.name,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                if (connection.created case final created?)
                  Text(
                    l10n.web3ConnectedAt(_formatTime(created, l10n)),
                    style: monoStyle(
                      fontSize: 11,
                      color: TibaneColors.textMuted,
                    ),
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
