import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/amount.dart';
import '../../utils/context_extensions.dart';
import '../../utils/wallet_error.dart';
import '../../widgets/tibane_card.dart';

/// Wallet recovery (libwallet `client.recovery`, docs/wallet-recovery.md):
/// bring funds over from another wallet's recovery phrase, private key,
/// Ethereum keystore file or Bitfi. The secret is only held in memory by
/// libwallet for the session and is wiped when this screen goes away; it never
/// becomes part of the user's wallet. Every transfer is shown to the user
/// before it is broadcast.
class RecoverFundsScreen extends StatefulWidget {
  const RecoverFundsScreen({super.key});

  @override
  State<RecoverFundsScreen> createState() => _RecoverFundsScreenState();
}

enum RecoverySourceKind { phrase, privateKey, keystore, bitfi }

/// The libwallet account type that can receive [chain]'s funds (`toAccount`).
/// Bitcoin-family chains all land on a `bitcoin` account, at its address for
/// that chain. Null for chains recovery can't move (Monero).
String? recoveryAccountTypeFor(String chain) => switch (chain) {
  'bitcoin' ||
  'litecoin' ||
  'dogecoin' ||
  'bitcoin-cash' ||
  'monacoin' => 'bitcoin',
  'ethereum' => 'ethereum',
  'solana' => 'solana',
  'tron' => 'tron',
  _ => null,
};

/// Decimals of [chain]'s native coin, in which every sweep fee is counted.
int recoveryNativeDecimals(String chain) => switch (chain) {
  'ethereum' => 18,
  'solana' => 9,
  'tron' => 6,
  'monero' => 12,
  _ => 8, // Bitcoin family
};

/// Whether a scan should go on past [count] addresses from [start]: wallets
/// use addresses in order, so funds on the last index checked mean the next
/// ones may hold some too.
bool recoveryShouldScanFurther(
  Iterable<RecoveredAddress> scanned, {
  required int start,
  required int count,
}) => scanned.any((a) => a.hasFunds && a.index >= start + count - 1);

class _RecoverFundsScreenState extends State<RecoverFundsScreen> {
  static const _pageSize = 5;

  RecoverySourceKind _kind = RecoverySourceKind.phrase;
  final _secretCtrl = TextEditingController();
  final _extraCtrl = TextEditingController(); // passphrase / password / salt
  bool _showSecret = false;

  RecoverySession? _session;
  bool _busy = false;
  String? _error;

  /// Every address scanned so far, by id (later scans replace earlier rows).
  final Map<String, RecoveredAddress> _scanned = {};
  int _scannedUpTo = 0; // next index to scan
  bool _thorough = false;

  /// Transfers already sent this session: `<address id>|<asset>` → txid.
  final Map<String, String> _sent = {};

  @override
  void dispose() {
    _secretCtrl.dispose();
    _extraCtrl.dispose();
    // The secret stays in libwallet's memory until the session is closed.
    final session = _session;
    if (session != null) unawaited(session.close().catchError((_) {}));
    super.dispose();
  }

  Future<LibwalletClient> _client() =>
      context.read<WalletService>().libwallet.ensureClient();

  RecoverySource _source() {
    final secret = _secretCtrl.text.trim();
    final extra = _extraCtrl.text;
    return switch (_kind) {
      RecoverySourceKind.phrase => RecoverySource.mnemonic(
        secret,
        passphrase: extra,
      ),
      RecoverySourceKind.privateKey => RecoverySource.privateKey(secret),
      RecoverySourceKind.keystore => RecoverySource.keystore(
        secret,
        password: extra,
      ),
      // Bitfi: salt and phrase exactly as typed into the device.
      RecoverySourceKind.bitfi => RecoverySource.bitfi(
        salt: extra.trim(),
        secret: _secretCtrl.text,
      ),
    };
  }

  Future<void> _open() async {
    if (_busy) return;
    final l10n = context.l10n;
    if (_secretCtrl.text.trim().isEmpty ||
        ((_kind == RecoverySourceKind.keystore ||
                _kind == RecoverySourceKind.bitfi) &&
            _extraCtrl.text.isEmpty)) {
      setState(() => _error = l10n.recoverErrMissingInput);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = await _client();
      final session = await client.recovery.open(_source());
      if (!mounted) {
        unawaited(session.close());
        return;
      }
      // Don't keep the secret around once libwallet has it.
      _secretCtrl.clear();
      _extraCtrl.clear();
      setState(() {
        _session = session;
        _scanned.clear();
        _sent.clear();
        _scannedUpTo = 0;
        _thorough = false;
      });
      await _scan(start: 0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = walletErrorMessageForContext(context, e);
      });
    }
  }

  Future<void> _scan({required int start, bool thorough = false}) async {
    final session = _session;
    if (session == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final useAll = thorough || _thorough;
      final rows = await session.scan(
        start: start,
        count: _pageSize,
        layouts: useAll && session.layouts.isNotEmpty ? const ['all'] : null,
        accounts: useAll && session.layouts.isNotEmpty ? 3 : 1,
      );
      if (!mounted) return;
      setState(() {
        for (final row in rows) {
          _scanned[row.id] = row;
        }
        if (thorough) _thorough = true;
        if (start + _pageSize > _scannedUpTo) _scannedUpTo = start + _pageSize;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = walletErrorMessageForContext(context, e);
      });
    }
  }

  /// Rescan the addresses whose check failed (a node error is never an empty
  /// balance).
  Future<void> _retryFailed() async {
    final pages = {
      for (final a in _scanned.values.where(_isFailed))
        a.index - a.index % _pageSize,
    }.toList()..sort();
    for (final start in pages) {
      await _scan(start: start);
      if (!mounted || _error != null) return;
    }
  }

  Future<void> _closeSession() async {
    final session = _session;
    setState(() {
      _session = null;
      _scanned.clear();
      _sent.clear();
      _error = null;
    });
    if (session != null) {
      try {
        await session.close();
      } catch (_) {}
    }
  }

  static bool _isMonero(RecoveredAddress a) => a.chain == 'monero';
  static bool _isFailed(RecoveredAddress a) => a.error != null && !_isMonero(a);

  // ------------------------------------------------------------------
  // Moving funds
  // ------------------------------------------------------------------

  Future<void> _sweep(RecoveredAddress address, RecoveredAsset asset) async {
    final session = _session;
    if (session == null || _busy) return;
    final l10n = context.l10n;
    final target = await showModalBottomSheet<_Destination>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TibaneColors.card,
      builder: (_) => _DestinationSheet(
        chain: address.chain,
        symbol: asset.symbol.isEmpty ? address.symbol : asset.symbol,
        accounts: _accountsFor(address.chain),
      ),
    );
    if (target == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    RecoverySweep sweep;
    try {
      sweep = await session.prepareSweep(
        address,
        toAccount: target.accountId,
        to: target.accountId == null ? target.address : null,
        asset: asset.asset,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = walletErrorMessageForContext(context, e);
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    // prepareSweep signs but never broadcasts: send only on the user's say-so.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) =>
          _SweepConfirmDialog(sweep: sweep, nativeSymbol: address.symbol),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final txid = await session.broadcast(sweep);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _sent['${address.id}|${asset.asset}'] = txid;
      });
      context.showSnackBar(SnackBar(content: Text(l10n.recoverSent)));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = walletErrorMessageForContext(context, e);
      });
    }
  }

  List<_AccountChoice> _accountsFor(String chain) {
    final type = recoveryAccountTypeFor(chain);
    if (type == null) return const [];
    final service = context.read<WalletService>();
    final wallets = service.accountsService.walletsById;
    return [
      for (final a in service.accountsService.rawAccounts)
        if (a.type == type && a.address.isNotEmpty && a.address != 'N/A')
          _AccountChoice(
            id: a.id,
            walletName: wallets[a.wallet]?.name ?? '',
            name: a.name,
            // A bitcoin account receives other Bitcoin-family coins at its
            // own address for that chain, not at the BTC address shown here.
            address: chain == type ? a.address : null,
          ),
    ];
  }

  Future<void> _export(RecoveredAddress address) async {
    final session = _session;
    if (session == null) return;
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(l10n.recoverExportTitle),
        content: Text(
          l10n.recoverExportWarning,
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
              l10n.recoverExportReveal,
              style: const TextStyle(color: TibaneColors.orange),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    RecoveredKeys keys;
    try {
      keys = await session.export(address);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = walletErrorMessageForContext(context, e));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _ExportedKeysDialog(address: address, keys: keys),
    );
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.recoverTitle)),
      body: SafeArea(
        child: _session == null
            ? _buildSource(context)
            : _buildResults(context),
      ),
    );
  }

  Widget _buildSource(BuildContext context) {
    final l10n = context.l10n;
    final labels = {
      RecoverySourceKind.phrase: l10n.recoverSourcePhrase,
      RecoverySourceKind.privateKey: l10n.recoverSourcePrivateKey,
      RecoverySourceKind.keystore: l10n.recoverSourceKeystore,
      RecoverySourceKind.bitfi: 'Bitfi',
    };
    final secretHint = switch (_kind) {
      RecoverySourceKind.phrase => l10n.recoverPhraseHint,
      RecoverySourceKind.privateKey => l10n.recoverPrivateKeyHint,
      RecoverySourceKind.keystore => l10n.recoverKeystoreHint,
      RecoverySourceKind.bitfi => l10n.recoverBitfiSecretHint,
    };
    final extraLabel = switch (_kind) {
      RecoverySourceKind.phrase => l10n.mnemonicPassphraseLabel,
      RecoverySourceKind.privateKey => null,
      RecoverySourceKind.keystore => l10n.recoverKeystorePassword,
      RecoverySourceKind.bitfi => l10n.recoverBitfiSalt,
    };
    // Keystore JSON and Bitfi phrases are text the user pastes or types in
    // full; keys and phrases are hidden by default.
    final multiline = _showSecret || _kind == RecoverySourceKind.keystore;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          l10n.recoverIntro,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kind in RecoverySourceKind.values)
              ChoiceChip(
                key: ValueKey('recover-source-${kind.name}'),
                label: Text(labels[kind]!),
                selected: _kind == kind,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _kind = kind;
                        _secretCtrl.clear();
                        _extraCtrl.clear();
                        _error = null;
                      }),
              ),
          ],
        ),
        const SizedBox(height: 18),
        if (_kind == RecoverySourceKind.bitfi) ...[
          _field(_extraCtrl, label: extraLabel!, obscure: false),
          const SizedBox(height: 12),
        ],
        TextField(
          key: const ValueKey('recover-secret'),
          controller: _secretCtrl,
          obscureText: !multiline,
          minLines: multiline ? 4 : 1,
          maxLines: multiline ? 8 : 1,
          keyboardType: multiline
              ? TextInputType.multiline
              : TextInputType.text,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          style: const TextStyle(color: TibaneColors.text, fontSize: 15),
          decoration: InputDecoration(
            hintText: secretHint,
            hintStyle: const TextStyle(color: TibaneColors.textMuted),
            suffixIcon: _kind == RecoverySourceKind.keystore
                ? IconButton(
                    tooltip: l10n.recoverPickFile,
                    onPressed: _busy ? null : _pickKeystore,
                    icon: const Icon(Icons.folder_open),
                  )
                : IconButton(
                    onPressed: () => setState(() => _showSecret = !_showSecret),
                    icon: Icon(
                      _showSecret ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
          ),
        ),
        if (_kind == RecoverySourceKind.phrase ||
            _kind == RecoverySourceKind.keystore) ...[
          const SizedBox(height: 12),
          _field(
            _extraCtrl,
            label: extraLabel!,
            obscure: true,
            helper: _kind == RecoverySourceKind.phrase
                ? l10n.mnemonicExtraPasswordHint
                : null,
          ),
        ],
        if (_kind == RecoverySourceKind.bitfi) ...[
          const SizedBox(height: 8),
          Text(
            l10n.recoverBitfiHint,
            style: const TextStyle(color: TibaneColors.textMuted, fontSize: 13),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const ValueKey('recover-open'),
          onPressed: _busy ? null : _open,
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            minimumSize: const Size.fromHeight(52),
          ),
          child: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: TibaneColors.black,
                  ),
                )
              : Text(
                  l10n.recoverFindFunds,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
        ),
        const SizedBox(height: 16),
        Text(
          l10n.recoverPrivacyNote,
          style: const TextStyle(color: TibaneColors.textDim, fontSize: 12),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController ctrl, {
    required String label,
    required bool obscure,
    String? helper,
  }) => TextField(
    controller: ctrl,
    obscureText: obscure,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    style: const TextStyle(color: TibaneColors.text, fontSize: 15),
    decoration: InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 4,
    ),
  );

  Future<void> _pickKeystore() async {
    try {
      final file = await openFile();
      if (file == null) return;
      if (await file.length() > 256 * 1024) {
        throw const FormatException('File too large');
      }
      final text = utf8.decode(await file.readAsBytes());
      if (!mounted) return;
      setState(() {
        _secretCtrl.text = text.trim();
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = context.l10n.recoverErrKeystoreFile);
    }
  }

  Widget _buildResults(BuildContext context) {
    final l10n = context.l10n;
    final session = _session!;
    final rows = _scanned.values.toList();
    final funded = rows.where((a) => a.hasFunds && !_isMonero(a)).toList();
    final failed = rows.where(_isFailed).toList();
    final monero = rows.where(_isMonero).toList();
    final empty = rows.length - funded.length - failed.length - monero.length;
    final further = recoveryShouldScanFurther(
      rows,
      start: _scannedUpTo - _pageSize,
      count: _pageSize,
    );
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              l10n.recoverScanSummary(rows.length, funded.length),
              style: const TextStyle(color: TibaneColors.textMuted),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: TibaneColors.error)),
            ],
            if (failed.isNotEmpty) ...[
              const SizedBox(height: 16),
              TibaneCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.recoverFailedTitle(failed.length),
                      style: const TextStyle(
                        color: TibaneColors.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final a in failed.take(5))
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${a.symbol} · ${a.label}: ${a.error}',
                          style: const TextStyle(
                            color: TibaneColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : _retryFailed,
                      child: Text(l10n.recoverRetry),
                    ),
                  ],
                ),
              ),
            ],
            for (final address in funded) ...[
              const SizedBox(height: 12),
              _addressCard(address),
            ],
            for (final address in monero) ...[
              const SizedBox(height: 12),
              _moneroCard(address),
            ],
            if (funded.isEmpty && failed.isEmpty && !_busy) ...[
              const SizedBox(height: 16),
              Text(
                l10n.recoverNothingFound,
                style: const TextStyle(color: TibaneColors.textMuted),
              ),
            ],
            const SizedBox(height: 20),
            if (further)
              Text(
                l10n.recoverScanFurtherHint,
                style: const TextStyle(color: TibaneColors.orange),
              ),
            OutlinedButton(
              onPressed: _busy ? null : () => _scan(start: _scannedUpTo),
              child: Text(l10n.recoverScanMore),
            ),
            if (session.layouts.isNotEmpty && !_thorough) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () async {
                        _scannedUpTo = 0;
                        await _scan(start: 0, thorough: true);
                      },
                child: Text(l10n.recoverScanThorough),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              l10n.recoverEmptyCount(empty),
              style: const TextStyle(color: TibaneColors.textDim, fontSize: 12),
            ),
            const SizedBox(height: 20),
            TextButton(
              onPressed: _busy ? null : _closeSession,
              child: Text(l10n.recoverDone),
            ),
          ],
        ),
        if (_busy)
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: LinearProgressIndicator(color: TibaneColors.orange),
          ),
      ],
    );
  }

  Widget _addressCard(RecoveredAddress address) {
    final l10n = context.l10n;
    return TibaneCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${address.symbol} · ${address.label}',
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20),
                onSelected: (_) => _export(address),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'export',
                    child: Text(l10n.recoverExportTitle),
                  ),
                ],
              ),
            ],
          ),
          SelectableText(
            address.address,
            style: monoStyle(fontSize: 12, color: TibaneColors.textMuted),
          ),
          if (address.path != null)
            Text(
              address.path!,
              style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
            ),
          const SizedBox(height: 10),
          // Tokens first: the native coin pays for moving them.
          for (final asset in address.sweepOrder) _assetRow(address, asset),
        ],
      ),
    );
  }

  Widget _assetRow(RecoveredAddress address, RecoveredAsset asset) {
    final l10n = context.l10n;
    final txid = _sent['${address.id}|${asset.asset}'];
    final symbol = asset.symbol.isNotEmpty
        ? asset.symbol
        : _shorten(asset.asset);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${formatExactTokenAmount(asset.balance, asset.decimals)} $symbol',
              style: monoStyle(fontSize: 14, color: TibaneColors.text),
            ),
          ),
          if (txid != null)
            IconButton(
              tooltip: l10n.recoverCopyTxid,
              icon: const Icon(Icons.check_circle, color: TibaneColors.orange),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: txid));
                context.showSnackBar(
                  SnackBar(content: Text(l10n.recoverTxidCopied)),
                );
              },
            )
          else
            TextButton(
              onPressed: _busy ? null : () => _sweep(address, asset),
              child: Text(
                l10n.recoverMove,
                style: const TextStyle(color: TibaneColors.orange),
              ),
            ),
        ],
      ),
    );
  }

  Widget _moneroCard(RecoveredAddress address) {
    final l10n = context.l10n;
    return TibaneCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'XMR · ${address.label}',
            style: const TextStyle(
              color: TibaneColors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.recoverMoneroNote,
            style: const TextStyle(color: TibaneColors.textMuted, fontSize: 13),
          ),
          TextButton(
            onPressed: () => _export(address),
            child: Text(l10n.recoverExportTitle),
          ),
        ],
      ),
    );
  }
}

String _shorten(String s) =>
    s.length <= 14 ? s : '${s.substring(0, 6)}…${s.substring(s.length - 6)}';

class _AccountChoice {
  const _AccountChoice({
    required this.id,
    required this.walletName,
    required this.name,
    this.address,
  });
  final String id;
  final String walletName;
  final String name;
  final String? address;
}

/// Where a sweep goes: one of the user's accounts (preferred: it can't be
/// mistyped or name another chain) or a typed address on the swept chain.
class _Destination {
  const _Destination.account(String this.accountId) : address = null;
  const _Destination.address(String this.address) : accountId = null;
  final String? accountId;
  final String? address;
}

class _DestinationSheet extends StatefulWidget {
  const _DestinationSheet({
    required this.chain,
    required this.symbol,
    required this.accounts,
  });
  final String chain;
  final String symbol;
  final List<_AccountChoice> accounts;

  @override
  State<_DestinationSheet> createState() => _DestinationSheetState();
}

class _DestinationSheetState extends State<_DestinationSheet> {
  final _addressCtrl = TextEditingController();
  late bool _typed = widget.accounts.isEmpty;

  @override
  void dispose() {
    _addressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.recoverDestinationTitle(widget.symbol),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (!_typed) ...[
            for (final a in widget.accounts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: Text(
                  [a.walletName, a.name].where((s) => s.isNotEmpty).join(' · '),
                ),
                subtitle: a.address == null
                    ? null
                    : Text(
                        _shorten(a.address!),
                        style: monoStyle(fontSize: 12),
                      ),
                onTap: () => Navigator.pop(context, _Destination.account(a.id)),
              ),
            TextButton(
              onPressed: () => setState(() => _typed = true),
              child: Text(l10n.recoverOtherAddress),
            ),
          ] else ...[
            if (widget.accounts.isEmpty)
              Text(
                l10n.recoverNoAccount(widget.symbol),
                style: const TextStyle(color: TibaneColors.textMuted),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _addressCtrl,
              autocorrect: false,
              enableSuggestions: false,
              style: monoStyle(fontSize: 14),
              decoration: InputDecoration(
                labelText: l10n.recoverAddressLabel(widget.symbol),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                final address = _addressCtrl.text.trim();
                if (address.isEmpty) return;
                Navigator.pop(context, _Destination.address(address));
              },
              child: Text(l10n.recoverContinue),
            ),
          ],
        ],
      ),
    );
  }
}

class _SweepConfirmDialog extends StatelessWidget {
  const _SweepConfirmDialog({required this.sweep, required this.nativeSymbol});
  final RecoverySweep sweep;
  final String nativeSymbol;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final symbol = sweep.symbol.isNotEmpty
        ? sweep.symbol
        : _shorten(sweep.asset);
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: TibaneColors.textMuted, fontSize: 12),
          ),
          SelectableText(value, style: monoStyle(fontSize: 14)),
        ],
      ),
    );
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      title: Text(l10n.recoverConfirmTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row(
              l10n.recoverConfirmAmount,
              '${formatExactTokenAmount(sweep.amount, sweep.decimals)} $symbol',
            ),
            // The fee is paid in the chain's native coin, whatever is moved.
            row(
              l10n.recoverConfirmFee,
              '${formatExactTokenAmount(sweep.fee, recoveryNativeDecimals(sweep.chain))} $nativeSymbol',
            ),
            row(l10n.recoverConfirmFrom, sweep.from),
            row(l10n.recoverConfirmTo, sweep.to),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.actionCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            l10n.recoverConfirmSend,
            style: const TextStyle(color: TibaneColors.orange),
          ),
        ),
      ],
    );
  }
}

class _ExportedKeysDialog extends StatelessWidget {
  const _ExportedKeysDialog({required this.address, required this.keys});
  final RecoveredAddress address;
  final RecoveredKeys keys;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = <(String, String)>[
      if (keys.privateKey != null) (l10n.recoverKeyPrivate, keys.privateKey!),
      if (keys.wif != null) ('WIF', keys.wif!),
      if (keys.spendKey != null) (l10n.recoverKeySpend, keys.spendKey!),
      if (keys.viewKey != null) (l10n.recoverKeyView, keys.viewKey!),
    ];
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      title: Text('${address.symbol} · ${address.label}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.recoverExportWarning,
              style: const TextStyle(color: TibaneColors.error, fontSize: 12),
            ),
            for (final (label, value) in entries) ...[
              const SizedBox(height: 12),
              Text(
                label,
                style: const TextStyle(
                  color: TibaneColors.textMuted,
                  fontSize: 12,
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      value,
                      style: monoStyle(fontSize: 12),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: value)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.actionClose),
        ),
      ],
    );
  }
}
