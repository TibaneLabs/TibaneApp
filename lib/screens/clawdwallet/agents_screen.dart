import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/token_account.dart';
import '../../services/clawdwallet_service.dart';
import '../../services/rpc_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../wallet/widgets/authorize_and_sign.dart';
import 'activity_screen.dart';
import 'create_agent_wallet_screen.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../widgets/wallet_error_display.dart';

/// USDC mainnet mint. Stage 1 demo flows transfer USDC.
const _usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

/// 6th tab — list of ClawdWallets the user owns. Tap a row to see activity,
/// flip the lock toggle to stop new sign-requests, hit the FAB to provision
/// a new wallet.
class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key});

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _wallets = const [];
  final Map<String, _BalanceSnapshot> _balances = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // Agent wallets run under the user's atonline session. Ensure it's
    // authenticated first — under lockless this signs the login ticket via the
    // sheet here (no eager auto-login); in the legacy session it's a no-op.
    if (!await ensureServerAuthenticated(context)) {
      if (!mounted) return;
      debugPrint('[agents] server authentication cancelled/failed');
      setState(() {
        _loading = false;
        _error = context.l10n.clawdAgentsSignInRequired;
      });
      return;
    }
    if (!mounted) return;
    try {
      final wallets = await ClawdWalletService().list();
      if (!mounted) return;
      setState(() {
        _wallets = wallets;
        _loading = false;
      });
      // Fetch balances opportunistically — these failures shouldn't block
      // the wallet list rendering.
      for (final w in wallets) {
        final addr = w['solana_address'] ?? w['address'];
        final id = w['id'];
        if (addr is String && addr.isNotEmpty && id is String) {
          _refreshBalance(id, addr);
        }
      }
    } catch (e) {
      // Keep the raw exception in the log for developers; WalletError maps it
      // (including the AtOnlinePlatformException payload) to a friendly message.
      logError('[Agents._load] list failed', e);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = WalletError.from(e).message;
      });
    }
  }

  Future<void> _refreshBalance(String id, String address) async {
    final rpc = RpcService();
    try {
      final sol = await rpc.getBalance(address);
      var usdc = BigInt.zero;
      try {
        final accounts = await rpc.getTokenAccountsByOwner(address);
        for (final TokenAccount a in accounts) {
          if (a.mint == _usdcMint) usdc += a.amount;
        }
      } catch (_) {
        // Token-account read can fail for fresh addresses; ignore.
      }
      if (!mounted) return;
      setState(() {
        _balances[id] = _BalanceSnapshot(sol: sol, usdc: usdc);
      });
    } catch (_) {
      // Silent — the UI will show "—" for the balance.
    } finally {
      rpc.dispose();
    }
  }

  Future<void> _toggleLock(Map<String, dynamic> wallet, bool locked) async {
    final id = wallet['id'] as String?;
    if (id == null) return;
    setState(() {
      wallet['locked'] = locked;
    });
    try {
      await ClawdWalletService().setLocked(id, locked);
    } catch (e) {
      logError('[Agents._toggleLock] set-locked error: $e');
      if (!mounted) return;
      // Roll back optimistic state and surface the failure.
      setState(() {
        wallet['locked'] = !locked;
      });
      showWalletError(context, e);
    }
  }

  Future<void> _openCreate() async {
    final newId = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const CreateAgentWalletScreen()),
    );
    if (newId != null) _load();
  }

  void _openActivity(Map<String, dynamic> w) {
    final id = w['id'] as String?;
    if (id == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ActivityScreen(
          walletId: id,
          walletName: (w['name'] as String?) ?? context.l10n.clawdAgentsDefaultWalletName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      body: SafeArea(
        child: RefreshIndicator(
          color: TibaneColors.orange,
          onRefresh: _load,
          child: _buildBody(),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreate,
        backgroundColor: TibaneColors.orange,
        foregroundColor: TibaneColors.black,
        icon: const Icon(Icons.add),
        label: Text(
          context.l10n.clawdAgentsNewAgent,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: TibaneColors.orange),
      );
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TibaneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.cloud_off_outlined, color: TibaneColors.error),
                const SizedBox(height: 10),
                Text(
                  context.l10n.clawdAgentsLoadError,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: TibaneColors.textMuted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    if (_wallets.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 40),
          const Icon(
            Icons.precision_manufacturing_outlined,
            size: 64,
            color: TibaneColors.textDim,
          ),
          const SizedBox(height: 18),
          Center(
            child: Text(
              context.l10n.clawdAgentsEmpty,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              context.l10n.clawdAgentsEmptyHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: TibaneColors.textMuted, height: 1.5),
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: _wallets.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, i) {
        final w = _wallets[i];
        return _AgentCard(
          wallet: w,
          balance: _balances[w['id']],
          onTap: () => _openActivity(w),
          onLockChanged: (v) => _toggleLock(w, v),
        );
      },
    );
  }
}

class _BalanceSnapshot {
  final BigInt sol;
  final BigInt usdc;

  const _BalanceSnapshot({required this.sol, required this.usdc});
}

class _AgentCard extends StatelessWidget {
  final Map<String, dynamic> wallet;
  final _BalanceSnapshot? balance;
  final VoidCallback onTap;
  final ValueChanged<bool> onLockChanged;

  const _AgentCard({
    required this.wallet,
    required this.balance,
    required this.onTap,
    required this.onLockChanged,
  });

  String _shortAddr(String? a) {
    if (a == null || a.isEmpty) return '—';
    if (a.length <= 12) return a;
    return '${a.substring(0, 6)}…${a.substring(a.length - 6)}';
  }

  String _formatSol(BigInt lamports) {
    final sol = lamports / BigInt.from(1000000000);
    return '${sol.toStringAsFixed(4)} SOL';
  }

  String _formatUsdc(BigInt raw) {
    // USDC has 6 decimals on Solana.
    final usdc = raw / BigInt.from(1000000);
    return '\$${usdc.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final name = (wallet['name'] as String?) ?? context.l10n.clawdAgentsDefaultWalletName;
    final addr = (wallet['solana_address'] ?? wallet['address']) as String?;
    final locked = wallet['locked'] == true;

    return TibaneCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (locked ? TibaneColors.error : TibaneColors.orange)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  locked ? Icons.lock : Icons.precision_manufacturing,
                  color: locked ? TibaneColors.error : TibaneColors.orange,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () {
                        if (addr == null) return;
                        Clipboard.setData(ClipboardData(text: addr));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(context.l10n.addressCopied),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      },
                      child: Text(
                        _shortAddr(addr),
                        style: monoStyle(
                          fontSize: 12,
                          color: TibaneColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _LockToggle(value: locked, onChanged: onLockChanged),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: TibaneColors.darker,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: TibaneColors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _BalanceCell(
                    label: 'SOL',
                    value: balance == null ? '—' : _formatSol(balance!.sol),
                  ),
                ),
                Container(width: 1, height: 28, color: TibaneColors.border),
                Expanded(
                  child: _BalanceCell(
                    label: 'USDC',
                    value: balance == null ? '—' : _formatUsdc(balance!.usdc),
                    valueColor: TibaneColors.gold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BalanceCell extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _BalanceCell({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label, style: monoStyle(fontSize: 9, color: TibaneColors.textDim)),
        const SizedBox(height: 4),
        Text(
          value,
          style: monoStyle(
            fontSize: 14,
            color: valueColor ?? TibaneColors.text,
          ),
        ),
      ],
    );
  }
}

class _LockToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _LockToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Tooltip(
      message: value
          ? l10n.clawdAgentsLockedTooltip
          : l10n.clawdAgentsUnlockedTooltip,
      child: Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeColor: TibaneColors.error,
        activeTrackColor: TibaneColors.error.withValues(alpha: 0.5),
      ),
    );
  }
}
