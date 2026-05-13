import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';

/// Import an existing BIP-39 mnemonic from another wallet (Phantom,
/// Backpack, MetaMask, etc.). Three steps:
///   1. Mnemonic + password → libwallet.importMnemonic creates a 1-of-1
///      mnemonic-backed wallet.
///   2. probeActivity scans all known BIP-44 derivation paths and reports
///      which chains have on-chain activity. The user picks which paths
///      to migrate (active ones are pre-selected).
///   3. promoteMnemonic spawns one MPC wallet per picked chain; the
///      source mnemonic wallet stays put as a safety net until the user
///      validates the new wallets.
class InAppImportMnemonicScreen extends StatefulWidget {
  const InAppImportMnemonicScreen({super.key});

  @override
  State<InAppImportMnemonicScreen> createState() =>
      _InAppImportMnemonicScreenState();
}

enum _Step { input, probing, picking, promoting, done, error }

class _InAppImportMnemonicScreenState extends State<InAppImportMnemonicScreen> {
  final _mnemonicCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();

  String _curve = 'ed25519';
  _Step _step = _Step.input;
  String? _error;

  Wallet? _imported;
  List<ProbeActivityRow> _rows = const [];
  final Set<int> _selected = <int>{};
  List<Wallet> _promoted = const [];

  @override
  void dispose() {
    _mnemonicCtrl.dispose();
    _passphraseCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _importAndProbe() async {
    final mnemonic = _mnemonicCtrl.text.trim();
    final pw = _pwCtrl.text;
    final words = mnemonic.split(RegExp(r'\s+'));
    if (![12, 15, 18, 21, 24].contains(words.length)) {
      setState(() => _error = 'Mnemonic must be 12/15/18/21/24 words');
      return;
    }
    if (pw.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }

    setState(() {
      _step = _Step.probing;
      _error = null;
    });
    try {
      final ws = context.read<WalletService>();
      final client = await ws.libwallet.ensureClient();
      final imported = await client.wallets.importMnemonic(
        mnemonic: mnemonic,
        passphrase: _passphraseCtrl.text,
        curve: _curve,
        name: 'Imported mnemonic',
        keys: [KeyDescription.password(pw)],
      );
      final rows = await client.wallets.probeActivity(
        imported.id,
        keys: [KeyDescription.password(pw)],
      );
      if (!mounted) return;
      // Pre-select rows that have on-chain activity. If nothing's active,
      // pre-select the first row of the curve we imported so the user
      // gets at least one default candidate.
      _selected.clear();
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].hasActivity) _selected.add(i);
      }
      if (_selected.isEmpty && rows.isNotEmpty) _selected.add(0);
      setState(() {
        _imported = imported;
        _rows = rows;
        _step = _Step.picking;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _step = _Step.error;
      });
    }
  }

  Future<void> _promote() async {
    final imported = _imported;
    if (imported == null || _selected.isEmpty) return;
    final pw = _pwCtrl.text;
    setState(() {
      _step = _Step.promoting;
      _error = null;
    });
    try {
      final ws = context.read<WalletService>();
      final client = await ws.libwallet.ensureClient();
      final chains = _selected
          .map((i) => ChainMigration.fromProbeRow(_rows.elementAt(i)))
          .toList();
      final promoted = await client.wallets.promoteMnemonic(
        imported.id,
        oldKeys: [KeyDescription.password(pw)],
        chains: chains,
        // For now wire the promoted MPC wallets with a single Password
        // share — keeps the migration UX tight. The user can re-share
        // with Store/Remote keys later via the wallet-rotate flow.
        newKeys: [KeyDescription.password(pw)],
        threshold: 1,
      );
      if (!mounted) return;
      setState(() {
        _promoted = promoted;
        _step = _Step.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _step = _Step.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Import mnemonic')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: switch (_step) {
            _Step.input => _buildInput(),
            _Step.probing => _buildBusy('Importing and probing chains…'),
            _Step.picking => _buildPicker(),
            _Step.promoting => _buildBusy('Creating MPC wallets…'),
            _Step.done => _buildDone(),
            _Step.error => _buildError(),
          },
        ),
      ),
    );
  }

  Widget _buildInput() {
    return ListView(
      children: [
        const Text(
          'Paste your BIP-39 mnemonic from another wallet. The phrase is '
          'imported into libwallet, encrypted at rest under the password '
          'you set below. Any chains with on-chain activity will be auto-'
          'detected in the next step.',
          style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _mnemonicCtrl,
          minLines: 3,
          maxLines: 5,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Mnemonic (12 / 15 / 18 / 21 / 24 words)',
          ),
          style: monoStyle(fontSize: 13),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passphraseCtrl,
          obscureText: true,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'BIP-39 passphrase (optional)',
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Curve',
          style: TextStyle(color: TibaneColors.textDim, fontSize: 12),
        ),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'ed25519', label: Text('Solana')),
            ButtonSegment(value: 'secp256k1', label: Text('EVM/BTC')),
          ],
          selected: {_curve},
          onSelectionChanged: (s) => setState(() => _curve = s.first),
        ),
        const SizedBox(height: 4),
        Text(
          _curve == 'ed25519'
              ? 'Imports the mnemonic with Solana derivation. Probe step will still scan EVM / BTC paths in case there is activity.'
              : 'Imports the mnemonic with secp256k1 derivation. Best fit when you got the phrase from MetaMask, Ledger, Trezor, or Bitcoin-only wallets.',
          style: const TextStyle(color: TibaneColors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _pwCtrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Password (encrypts the imported share)',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _importAndProbe,
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text(
            'Import and scan',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'These are the BIP-44 paths libwallet probed under your mnemonic. '
          'Paths with on-chain activity are pre-selected. Picked paths get '
          'their own MPC wallet on the next step.',
          style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: _rows.isEmpty
              ? const Center(
                  child: Text(
                    'No derivation paths returned — check your mnemonic and try again.',
                    style: TextStyle(color: TibaneColors.textMuted),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.separated(
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (_, i) => _ProbeRowTile(
                    row: _rows[i],
                    selected: _selected.contains(i),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selected.add(i);
                      } else {
                        _selected.remove(i);
                      }
                    }),
                  ),
                ),
        ),
        const SizedBox(height: 16),
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
          const SizedBox(height: 12),
        ],
        FilledButton(
          onPressed: _selected.isEmpty ? null : _promote,
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(
            'Migrate ${_selected.length} '
            '${_selected.length == 1 ? "chain" : "chains"}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildBusy(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 56,
            height: 56,
            child: CircularProgressIndicator(
              color: TibaneColors.orange,
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            message,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDone() {
    return ListView(
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle,
                color: TibaneColors.cyan, size: 28),
            const SizedBox(width: 12),
            Text(
              'Import complete',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '${_promoted.length} '
          '${_promoted.length == 1 ? "wallet" : "wallets"} created. The '
          'source mnemonic wallet stays on-device as a safety net until '
          'you verify the new wallets — you can remove it later from '
          'Settings → Manage wallets.',
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        for (final w in _promoted)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: TibaneColors.darker,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.shield_outlined,
                      color: TibaneColors.orange, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          w.name,
                          style: const TextStyle(color: TibaneColors.text),
                        ),
                        Text(
                          '${w.curve} · ${w.pubkey.length > 14 ? "${w.pubkey.substring(0, 6)}…${w.pubkey.substring(w.pubkey.length - 6)}" : w.pubkey}',
                          style: monoStyle(
                              fontSize: 11, color: TibaneColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text('Done',
              style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: const [
            Icon(Icons.error_outline, color: TibaneColors.error, size: 24),
            SizedBox(width: 10),
            Text(
              'Import failed',
              style: TextStyle(
                color: TibaneColors.text,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SelectableText(
          _error ?? 'Unknown error',
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const Spacer(),
        FilledButton(
          onPressed: () => setState(() {
            _step = _Step.input;
            _error = null;
          }),
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text('Start over',
              style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _ProbeRowTile extends StatelessWidget {
  final ProbeActivityRow row;
  final bool selected;
  final ValueChanged<bool?> onChanged;

  const _ProbeRowTile({
    required this.row,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final addr = row.address;
    final preview = addr.length > 14
        ? '${addr.substring(0, 6)}…${addr.substring(addr.length - 6)}'
        : addr;
    return CheckboxListTile(
      value: selected,
      onChanged: onChanged,
      activeColor: TibaneColors.orange,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Row(
        children: [
          Expanded(
            child: Text(
              '${row.network} · ${row.variant}',
              style: const TextStyle(color: TibaneColors.text, fontSize: 14),
            ),
          ),
          if (row.hasActivity)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: TibaneColors.cyan.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Active',
                style: monoStyle(fontSize: 9, color: TibaneColors.cyan),
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            preview,
            style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
          ),
          if (row.derivationPath.isNotEmpty)
            Text(
              row.derivationPath,
              style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
            ),
          if (row.error.isNotEmpty)
            Text(
              'probe error: ${row.error}',
              style: const TextStyle(color: TibaneColors.error, fontSize: 10),
            ),
        ],
      ),
    );
  }
}
