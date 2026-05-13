import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';

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
        _walletsById = {
          for (final w in results[1] as List<lw.Wallet>) w.id: w,
        };
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

  Future<void> _addAccount() async {
    final wallets = _walletsById.values.toList();
    if (wallets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Create a wallet first.'),
      ));
      return;
    }
    final created = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: TibaneColors.card,
      isScrollControlled: true,
      builder: (_) => _AddAccountSheet(wallets: wallets),
    );
    if (created == true) _load();
  }

  Future<void> _setActive(lw.Account account) async {
    final ws = context.read<WalletService>();
    if (ws.libwallet.accountId == account.id) return;
    final ok = await ws.libwallet.switchAccount(account.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ws.libwallet.error ?? 'Could not switch account'),
      ));
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
      final client = await context.read<WalletService>().libwallet.ensureClient();
      await client.accounts.delete(account.id);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Remove failed: $e')),
      );
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
        onPressed: _addAccount,
        icon: const Icon(Icons.add),
        label: const Text('New account'),
      ),
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
                child: Text(_error!,
                    style:
                        const TextStyle(color: TibaneColors.textMuted),
                    textAlign: TextAlign.center),
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
                    const Icon(Icons.account_circle_outlined,
                        size: 48, color: TibaneColors.textDim),
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
        }),
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
                        style:
                            const TextStyle(color: TibaneColors.text, fontSize: 15),
                      ),
                    ),
                    if (active)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: TibaneColors.cyan.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Active',
                          style:
                              monoStyle(fontSize: 9, color: TibaneColors.cyan),
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
                            fontSize: 11, color: TibaneColors.textMuted),
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
                        child: Icon(Icons.copy, size: 12, color: TibaneColors.textDim),
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

class _AddAccountSheet extends StatefulWidget {
  final List<lw.Wallet> wallets;
  const _AddAccountSheet({required this.wallets});

  @override
  State<_AddAccountSheet> createState() => _AddAccountSheetState();
}

class _AddAccountSheetState extends State<_AddAccountSheet> {
  late lw.Wallet _wallet = widget.wallets.first;
  String _type = '';
  final _nameCtrl = TextEditingController();
  final _indexCtrl = TextEditingController(text: '0');
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _type = _typesFor(_wallet).first;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _indexCtrl.dispose();
    super.dispose();
  }

  /// Curve → account types that can be derived from it.
  List<String> _typesFor(lw.Wallet w) {
    return w.curve == 'ed25519' ? const ['solana'] : const ['ethereum', 'bitcoin'];
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    final index = int.tryParse(_indexCtrl.text.trim());
    if (name.isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    if (index == null || index < 0) {
      setState(() => _error = 'Index must be a non-negative integer');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = await context.read<WalletService>().libwallet.ensureClient();
      await client.accounts.create(
        name: name,
        wallet: _wallet.id,
        type: _type,
        index: index,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = _typesFor(_wallet);
    if (!types.contains(_type)) _type = types.first;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'New account',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _wallet.id,
            decoration: const InputDecoration(labelText: 'Parent wallet'),
            items: [
              for (final w in widget.wallets)
                DropdownMenuItem(
                  value: w.id,
                  child: Text(
                    '${w.name.isEmpty ? "(unnamed)" : w.name} · ${w.curve}',
                  ),
                ),
            ],
            onChanged: _busy
                ? null
                : (id) {
                    if (id == null) return;
                    setState(() {
                      _wallet = widget.wallets.firstWhere((w) => w.id == id);
                    });
                  },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Type'),
            items: [
              for (final t in types)
                DropdownMenuItem(value: t, child: Text(t)),
            ],
            onChanged: _busy ? null : (t) => setState(() => _type = t ?? _type),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameCtrl,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Account name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _indexCtrl,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Derivation index',
              helperText: 'BIP-44 account index (default 0)',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: TibaneColors.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _create,
            style: FilledButton.styleFrom(
              backgroundColor: TibaneColors.orange,
              foregroundColor: TibaneColors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(
              _busy ? 'Creating…' : 'Create',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
