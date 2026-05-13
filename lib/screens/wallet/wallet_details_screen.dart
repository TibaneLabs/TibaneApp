import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import 'inapp_export_screen.dart';
import 'share_labels.dart';

/// Wallet detail view. When [walletId] is null, falls back to the
/// active in-app wallet (legacy callers); otherwise shows the wallet
/// fetched by id via libwallet.
class WalletDetailsScreen extends StatefulWidget {
  final String? walletId;
  const WalletDetailsScreen({super.key, this.walletId});

  @override
  State<WalletDetailsScreen> createState() => _WalletDetailsScreenState();
}

class _WalletDetailsScreenState extends State<WalletDetailsScreen> {
  lw.Wallet? _wallet;
  List<lw.Account> _accounts = const [];
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ws = context.read<WalletService>();
    final id = widget.walletId ?? ws.libwallet.walletId;
    if (id == null) {
      setState(() {
        _loading = false;
        _loadError = 'No wallet selected';
      });
      return;
    }
    try {
      final client = await ws.libwallet.ensureClient();
      final results = await Future.wait([
        client.wallets.get(id),
        client.accounts.list(wallet: id),
      ]);
      if (!mounted) return;
      setState(() {
        _wallet = results[0] as lw.Wallet;
        _accounts = results[1] as List<lw.Account>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.toString();
      });
    }
  }

  Future<void> _backup() async {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const InAppExportScreen()),
    );
  }

  Future<void> _remove() async {
    final wallet = _wallet;
    if (wallet == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: const Text('Remove wallet?'),
        content: const Text(
          'This deletes the wallet from this device. If you have not backed '
          'it up, the funds will be irrecoverable. Continue?',
          style: TextStyle(color: TibaneColors.textMuted),
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
    final ws = context.read<WalletService>();
    final client = await ws.libwallet.ensureClient();
    try {
      await client.wallets.delete(wallet.id);
      if (wallet.id == ws.libwallet.walletId) {
        await ws.disconnect();
      }
      if (!mounted) return;
      Navigator.of(context).pop();
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
      appBar: AppBar(title: const Text('Wallet')),
      body: SafeArea(
        child: Builder(builder: (context) {
          if (_loading) {
            return const Center(
              child: CircularProgressIndicator(color: TibaneColors.orange),
            );
          }
          if (_loadError != null || _wallet == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  _loadError ?? 'No wallet',
                  style: const TextStyle(color: TibaneColors.textMuted),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HeaderCard(wallet: _wallet!),
                const SizedBox(height: 20),
                _SharesCard(wallet: _wallet!),
                const SizedBox(height: 20),
                _AccountsCard(accounts: _accounts),
                const SizedBox(height: 20),
                _ActionsRow(onBackup: _backup, onRemove: _remove),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final lw.Wallet wallet;
  const _HeaderCard({required this.wallet});

  @override
  Widget build(BuildContext context) {
    final threshold = wallet.keys.length >= 2 ? wallet.keys.length - 1 : 1;
    return TibaneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            wallet.name.isEmpty ? '(unnamed)' : wallet.name,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            'In-app MPC wallet · $threshold-of-${wallet.keys.length} '
            '${wallet.curve == "ed25519" ? "EdDSA (Solana)" : "ECDSA (EVM/Bitcoin)"}',
            style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
          ),
          const SizedBox(height: 14),
          Text(
            'MASTER PUBLIC KEY',
            style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  wallet.pubkey,
                  style: monoStyle(fontSize: 11),
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: wallet.pubkey));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Public key copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SharesCard extends StatelessWidget {
  final lw.Wallet wallet;
  const _SharesCard({required this.wallet});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'KEY SHARES',
          style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 6),
        Text(
          'Any ${(wallet.keys.length - 1).clamp(1, wallet.keys.length)} of these '
          '${wallet.keys.length} shares are enough to sign. No single party '
          'can move funds alone.',
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 12),
        for (final k in wallet.keys) ...[
          _ShareRow(type: k.type),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _ShareRow extends StatelessWidget {
  final String type;
  const _ShareRow({required this.type});

  @override
  Widget build(BuildContext context) {
    final (icon, protection) = _meta(type);
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: TibaneColors.orange.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: TibaneColors.orange, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  shareTypeLabel(type),
                  style: const TextStyle(color: TibaneColors.text, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  protection,
                  style: const TextStyle(
                    color: TibaneColors.textMuted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static (IconData, String) _meta(String type) {
    switch (type) {
      case 'StoreKey':
        return (
          Icons.phone_iphone,
          'On this device. Encrypted at rest in the OS keystore '
              '(Keychain / Keystore); falls back to a password-derived '
              'AES-GCM blob if the keystore is unavailable.',
        );
      case 'RemoteKey':
        return (
          Icons.cloud_outlined,
          'Held on the Tibane key server, gated by the email or phone '
              'number you verified at setup. Recoverable on a new device '
              'by re-verifying that contact.',
        );
      case 'Password':
        return (
          Icons.password,
          'A password only you know, kept in memory only while the wallet '
              'is unlocked. Optional biometric unlock skips the password '
              'prompt at signing time.',
        );
      case 'Plain':
        return (
          Icons.key_outlined,
          'Imported share. Stored alongside other key material under the '
              'same protection.',
        );
      default:
        return (Icons.help_outline, type);
    }
  }
}

class _AccountsCard extends StatelessWidget {
  final List<lw.Account> accounts;
  const _AccountsCard({required this.accounts});

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) {
      return TibaneCard(
        child: Row(
          children: const [
            Icon(Icons.account_circle_outlined,
                color: TibaneColors.textMuted, size: 18),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'No chain accounts derived from this wallet yet.',
                style: TextStyle(color: TibaneColors.textMuted),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ACCOUNTS DERIVED FROM THIS WALLET',
          style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < accounts.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          _AccountRow(account: accounts[i]),
        ],
      ],
    );
  }
}

class _AccountRow extends StatelessWidget {
  final lw.Account account;
  const _AccountRow({required this.account});

  @override
  Widget build(BuildContext context) {
    final addr = account.address;
    final preview = addr.length > 14
        ? '${addr.substring(0, 6)}…${addr.substring(addr.length - 6)}'
        : addr;
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.account_circle_outlined,
              color: TibaneColors.textMuted, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  account.name.isEmpty ? account.type : account.name,
                  style: const TextStyle(color: TibaneColors.text, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  '${account.type} · $preview',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
                if (account.path.isNotEmpty)
                  Text(
                    'Derivation: ${account.path}',
                    style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionsRow extends StatelessWidget {
  final VoidCallback onBackup;
  final VoidCallback onRemove;
  const _ActionsRow({required this.onBackup, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onBackup,
            icon: const Icon(Icons.download_outlined, size: 16),
            label: const Text('Backup'),
            style: OutlinedButton.styleFrom(
              foregroundColor: TibaneColors.text,
              side: const BorderSide(color: TibaneColors.border),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Remove'),
            style: OutlinedButton.styleFrom(
              foregroundColor: TibaneColors.error,
              side: const BorderSide(color: TibaneColors.error),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }
}
