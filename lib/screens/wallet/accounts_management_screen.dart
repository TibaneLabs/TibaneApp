import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import '../../services/wallet/libwallet_backend.dart'
    show AccountSwitchRoute, LibwalletBackend;
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import 'inapp_create_screen.dart';
import 'inapp_unlock_screen.dart';

/// Lists every chain account derived from libwallet wallets on this
/// device. Shows the parent wallet, the chain type, the on-chain
/// address, and (for secp256k1 chains) the BIP-32 derivation path so
/// the user can verify what each account is.
///
/// FAB pushes a small "Add account" sheet that asks for the parent
/// wallet, account type, and index. Removal is a row tap → confirm
/// dialog.
class AccountsManagementScreen extends StatefulWidget {
  const AccountsManagementScreen({super.key});

  @override
  State<AccountsManagementScreen> createState() =>
      _AccountsManagementScreenState();
}

class _AccountsManagementScreenState extends State<AccountsManagementScreen> {
  List<lw.Account>? _accounts;
  Map<String, lw.Wallet> _walletsById = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ws = context.read<WalletService>();
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final client = await ws.libwallet.ensureClient();
      final results = await Future.wait([
        client.accounts.list(),
        client.wallets.list(),
      ]);
      if (!mounted) return;
      setState(() {
        _accounts = results[0] as List<lw.Account>;
        _walletsById = {for (final w in results[1] as List<lw.Wallet>) w.id: w};
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

  Future<void> _setActive(lw.Account account) async {
    final ws = context.read<WalletService>();
    final backend = ws.libwallet;
    final route = LibwalletBackend.accountSwitchRoute(
      targetAccountId: account.id,
      currentAccountId: backend.accountId,
      targetWalletId: account.wallet,
      activeWalletId: backend.walletId,
    );
    switch (route) {
      case AccountSwitchRoute.alreadyCurrent:
        return;
      case AccountSwitchRoute.sameWallet:
        break;
      case AccountSwitchRoute.crossWallet:
        // The account lives on a different wallet — switch (and unlock) that
        // wallet first, then select the specific account below.
        final switched = await InAppUnlockScreen.ensureUnlocked(
          context,
          walletId: account.wallet,
        );
        if (!mounted) return;
        if (!switched) return; // user cancelled / failed
        break;
    }
    final ok = await backend.switchAccount(account.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(backend.error ?? 'Could not switch account')),
      );
      return;
    }
    // Refresh balances for the new active account so the UI updates.
    ws.refreshBalances();
  }

  Future<void> _remove(lw.Account account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: const Text('Remove account?'),
        content: Text(
          'Remove the ${account.type} account at ${account.path.isNotEmpty ? account.path : "index 0"}? '
          'The parent wallet and its shares are untouched.',
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: TibaneColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    try {
      final client = await context
          .read<WalletService>()
          .libwallet
          .ensureClient();
      await client.accounts.delete(account.id);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Remove failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Accounts')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: TibaneColors.orange,
        foregroundColor: TibaneColors.black,
        // Adding a second account derived from the same wallet would
        // expose two on-chain addresses backed by the same master key,
        // which is rarely what the user wants (privacy + recovery
        // ambiguity). Route the "more addresses" intent to a fresh
        // wallet instead — each wallet has its own TSS shares.
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const InAppCreateScreen())),
        icon: const Icon(Icons.add),
        label: const Text('New wallet'),
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
            final list = _accounts ?? const [];
            if (list.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.account_circle_outlined,
                        size: 48,
                        color: TibaneColors.textDim,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No accounts yet',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Tap "New account" once a wallet exists.',
                        style: TextStyle(color: TibaneColors.textMuted),
                      ),
                    ],
                  ),
                ),
              );
            }
            final activeId = context.watch<WalletService>().libwallet.accountId;
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _AccountTile(
                account: list[i],
                walletName: _walletsById[list[i].wallet]?.name ?? '',
                active: list[i].id == activeId,
                onTap: () => _setActive(list[i]),
                onRemove: () => _remove(list[i]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  final lw.Account account;
  final String walletName;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _AccountTile({
    required this.account,
    required this.walletName,
    required this.active,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final addr = account.address;
    return TibaneCard(
      onTap: active ? null : onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(
            active ? Icons.account_circle : Icons.account_circle_outlined,
            color: active ? TibaneColors.orange : TibaneColors.textMuted,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        account.name.isEmpty ? account.type : account.name,
                        style: const TextStyle(
                          color: TibaneColors.text,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (active)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: TibaneColors.cyan.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Active',
                          style: monoStyle(
                            fontSize: 9,
                            color: TibaneColors.cyan,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${account.type} · $addr',
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          fontSize: 11,
                          color: TibaneColors.textMuted,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: addr));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Address copied'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.copy,
                          size: 12,
                          color: TibaneColors.textDim,
                        ),
                      ),
                    ),
                  ],
                ),
                if (account.path.isNotEmpty)
                  Text(
                    'Derivation: ${account.path}',
                    style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                  ),
                if (walletName.isNotEmpty)
                  Text(
                    'From wallet: $walletName',
                    style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline, size: 18),
            color: TibaneColors.error,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
