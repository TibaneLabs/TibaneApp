import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show Amount, TransactionSimulation;
import 'package:provider/provider.dart';

import '../../constants/solana_constants.dart';
import '../../services/jupiter_service.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/keyboard_safe_form.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/token_icon.dart';
import 'inapp_unlock_screen.dart';

class SendScreen extends StatefulWidget {
  /// Optional SPL mint to send instead of native SOL. When null the
  /// screen behaves as a SOL transfer (the default).
  final String? mint;

  /// Ticker shown in the AppBar / amount label when [mint] is set.
  final String? symbol;

  /// On-chain decimals for [mint]. Required when [mint] is non-null
  /// — the scale of the amount input depends on it.
  final int? decimals;

  const SendScreen({super.key, this.mint, this.symbol, this.decimals});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _addrCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  bool _sending = false;
  String? _error;
  String? _successHash;

  // ENS / SNS resolution state for the recipient field.
  Timer? _resolveDebounce;
  String? _resolvingName;
  String? _resolvedAddress;
  String? _resolvedName;
  String? _resolveError;

  // Currently selected token. A null [_mint] means native SOL; non-null
  // is the SPL mint address. [_symbol] / [_decimals] / [_imageUrl] are
  // mirrored as state so the picker can update them without losing the
  // widget-supplied default.
  String? _mint;
  String _symbol = 'SOL';
  int _decimals = 9;
  String? _imageUrl;

  // Tokens to offer in the picker. Loaded once on mount; empty list
  // until the fetch resolves (in which case the picker still shows the
  // native SOL row built from [WalletService.solBalance]).
  final JupiterService _jupiter = JupiterService();
  List<TokenHolding> _holdings = [];
  bool _loadingHoldings = true;

  @override
  void initState() {
    super.initState();
    _mint = widget.mint;
    _symbol = widget.symbol ?? 'SOL';
    _decimals = widget.decimals ?? 9;
    _addrCtrl.addListener(_onAddrChanged);
    _loadHoldings();
  }

  @override
  void dispose() {
    _addrCtrl.removeListener(_onAddrChanged);
    _resolveDebounce?.cancel();
    _addrCtrl.dispose();
    _amountCtrl.dispose();
    _jupiter.dispose();
    super.dispose();
  }

  Future<void> _loadHoldings() async {
    final wallet = context.read<WalletService>();
    final addr = wallet.publicKey;
    if (addr == null) {
      if (mounted) setState(() => _loadingHoldings = false);
      return;
    }
    try {
      // wsolMint is excluded so it doesn't duplicate the native SOL row
      // the picker always renders from wallet.solBalance.
      final holdings = await _jupiter.fetchHoldings(
        addr,
        excludeMint: wsolMint,
      );
      if (!mounted) return;
      setState(() {
        _holdings = holdings;
        _loadingHoldings = false;
        // If we were opened for a specific SPL mint, pull its imageUrl
        // from the freshly-loaded holdings so the selector chip shows a
        // proper logo instead of the letter-placeholder.
        if (_mint != null && _imageUrl == null) {
          for (final h in holdings) {
            if (h.mint == _mint) {
              _imageUrl = h.imageUrl;
              break;
            }
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingHoldings = false);
      debugPrint('[send] holdings load failed: $e');
    }
  }

  void _selectToken({
    required String? mint,
    required String symbol,
    required int decimals,
    String? imageUrl,
  }) {
    if (mint == _mint) return;
    setState(() {
      _mint = mint;
      _symbol = symbol;
      _decimals = decimals;
      _imageUrl = imageUrl;
      _amountCtrl.clear();
      _error = null;
      _successHash = null;
    });
  }

  Future<void> _openTokenPicker() async {
    if (_sending) return;
    final wallet = context.read<WalletService>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TibaneColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SendTokenPicker(
        holdings: _holdings,
        loading: _loadingHoldings,
        solBalance: wallet.solBalance,
        selectedMint: _mint,
        onSelect: (mint, symbol, decimals, imageUrl) {
          Navigator.pop(ctx);
          _selectToken(
            mint: mint,
            symbol: symbol,
            decimals: decimals,
            imageUrl: imageUrl,
          );
        },
      ),
    );
  }

  void _onAddrChanged() {
    final raw = _addrCtrl.text.trim();
    // Only resolve when the input looks like a name (contains a dot and
    // isn't already a base58/0x-shaped address). Solana addresses are
    // 32-44 chars and don't contain dots, so a "." is a robust signal.
    final looksLikeName =
        raw.contains('.') && !raw.startsWith('0x') && raw.length < 64;
    if (!looksLikeName) {
      if (_resolvedAddress != null ||
          _resolvingName != null ||
          _resolveError != null) {
        setState(() {
          _resolvingName = null;
          _resolvedAddress = null;
          _resolvedName = null;
          _resolveError = null;
        });
      }
      return;
    }
    if (raw == _resolvedName || raw == _resolvingName) return;
    _resolveDebounce?.cancel();
    _resolveDebounce = Timer(const Duration(milliseconds: 350), () {
      _resolveName(raw);
    });
  }

  Future<void> _resolveName(String name) async {
    setState(() {
      _resolvingName = name;
      _resolvedAddress = null;
      _resolvedName = null;
      _resolveError = null;
    });
    try {
      final wallet = context.read<WalletService>();
      final client = await wallet.libwallet.ensureClient();
      final r = await client.names.resolve(name);
      if (!mounted) return;
      // Only commit the result if the input is still the name we resolved
      // — otherwise the user kept typing and we should drop this answer.
      if (_addrCtrl.text.trim() != name) return;
      setState(() {
        _resolvingName = null;
        _resolvedName = name;
        _resolvedAddress = r.address;
      });
    } catch (e) {
      if (!mounted) return;
      if (_addrCtrl.text.trim() != name) return;
      setState(() {
        _resolvingName = null;
        _resolveError = 'Could not resolve $name';
      });
    }
  }

  Future<void> _setMax() async {
    final wallet = context.read<WalletService>();
    try {
      final result = await wallet.libwallet.maxSendable(
        to: _addrCtrl.text.trim().isNotEmpty ? _addrCtrl.text.trim() : null,
        asset: _assetKey,
      );
      if (!mounted) return;
      // result.max is an Amount scaled by the asset's decimals.
      final ui = result.max.toDouble();
      _amountCtrl.text = ui
          .toStringAsFixed(_decimals)
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'\.$'), '');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not compute max: $e');
    }
  }

  /// Asset key passed to libwallet (`solana.mainnet.<mint>`) when an
  /// SPL mint is selected, else null for the native-SOL path.
  String? get _assetKey {
    final mint = _mint;
    if (mint == null) return null;
    return 'solana.mainnet.$mint';
  }

  Future<void> _send() async {
    final typed = _addrCtrl.text.trim();
    // If the user typed a name that resolved, use the resolved address.
    final addr = (typed == _resolvedName && _resolvedAddress != null)
        ? _resolvedAddress!
        : typed;
    if (addr.length < 32) {
      setState(() => _error = 'Enter a valid Solana address');
      return;
    }
    final amountFloat = double.tryParse(_amountCtrl.text.trim());
    if (amountFloat == null || amountFloat <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    final scale = BigInt.from(10).pow(_decimals);
    final raw = BigInt.from((amountFloat * scale.toDouble()).round());
    final amount = Amount(raw, _decimals);

    // Pre-flight: simulate before asking for the password / FaceID. This
    // catches "recipient_new_account" rent advice, "will revert" failures,
    // and surfaces the predicted balance changes to the user before any
    // keys come out.
    setState(() {
      _sending = true;
      _error = null;
      _successHash = null;
    });
    TransactionSimulation? sim;
    try {
      final wallet = context.read<WalletService>();
      sim = await wallet.libwallet.simulateSend(
        to: addr,
        amount: amount,
        asset: _assetKey,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Simulation failed: $e';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _sending = false);
    final approved = await _showReviewSheet(addr, amountFloat, sim);
    if (approved != true) return;
    if (!mounted) return;

    if (!await InAppUnlockScreen.ensureUnlocked(context)) return;
    if (!mounted) return;

    setState(() {
      _sending = true;
      _error = null;
      _successHash = null;
    });

    final wallet = context.read<WalletService>();
    try {
      final tx = await wallet.libwallet.send(
        to: addr,
        amount: amount,
        asset: _assetKey,
      );
      if (!mounted) return;
      setState(() {
        _successHash = tx.hash;
        _amountCtrl.clear();
      });
      wallet.refreshBalances();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<bool?> _showReviewSheet(
    String to,
    double amountUi,
    TransactionSimulation sim,
  ) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TibaneColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SendReviewSheet(
        to: to,
        amountUi: amountUi,
        symbol: _symbol,
        decimals: _decimals,
        sim: sim,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text('Send $_symbol')),
      body: SafeArea(
        child: GestureDetector(
          // Tap outside any input to dismiss the iOS numeric keyboard.
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: KeyboardSafeForm(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TokenSelector(
                  mint: _mint,
                  symbol: _symbol,
                  imageUrl: _imageUrl,
                  loading: _loadingHoldings,
                  onTap: _sending ? null : _openTokenPicker,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _addrCtrl,
                  enabled: !_sending,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Recipient address or name',
                    helperText: 'Solana address, .sol name, or .eth name',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.paste, size: 18),
                      onPressed: _sending
                          ? null
                          : () async {
                              final clip = await Clipboard.getData(
                                'text/plain',
                              );
                              if (clip?.text != null)
                                _addrCtrl.text = clip!.text!;
                            },
                    ),
                  ),
                ),
                if (_resolvingName != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: TibaneColors.textMuted,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Resolving $_resolvingName…',
                        style: const TextStyle(
                          color: TibaneColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ] else if (_resolvedAddress != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: TibaneColors.cyan,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _resolvedAddress!,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(
                            fontSize: 12,
                            color: TibaneColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else if (_resolveError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _resolveError!,
                    style: const TextStyle(
                      color: TibaneColors.error,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _amountCtrl,
                  enabled: !_sending,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Amount ($_symbol)',
                    suffixIcon: TextButton(
                      onPressed: _sending ? null : _setMax,
                      child: const Text('MAX', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: TibaneColors.error,
                      fontSize: 13,
                    ),
                  ),
                ],
                if (_successHash != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: TibaneColors.cyan,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Sent!',
                              style: TextStyle(
                                color: TibaneColors.cyan,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              shortenAddress(_successHash!, chars: 12),
                              style: monoStyle(
                                fontSize: 11,
                                color: TibaneColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
                const Spacer(),
                FilledButton(
                  onPressed: _sending ? null : _send,
                  style: FilledButton.styleFrom(
                    backgroundColor: TibaneColors.orange,
                    foregroundColor: TibaneColors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    _sending ? 'Sending...' : 'Send',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pre-broadcast review of an outgoing transfer. Surfaces what libwallet's
/// `Transaction:simulate` predicts (will-revert flag, recipient rent, etc.)
/// before the user is asked to authenticate the send.
class _SendReviewSheet extends StatelessWidget {
  final String to;
  final double amountUi;
  final String symbol;
  final int decimals;
  final TransactionSimulation sim;

  const _SendReviewSheet({
    required this.to,
    required this.amountUi,
    required this.symbol,
    required this.decimals,
    required this.sim,
  });

  @override
  Widget build(BuildContext context) {
    final shortTo = to.length > 14
        ? '${to.substring(0, 6)}…${to.substring(to.length - 6)}'
        : to;
    final blocking =
        sim.willRevert || sim.warnings.any((w) => w.severity == 'block');
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: TibaneColors.textDim,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Review send', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          _kv('To', shortTo),
          const SizedBox(height: 8),
          _kv(
            'Amount',
            '${amountUi.toStringAsFixed(decimals).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')} $symbol',
          ),
          if (sim.unitsConsumed != null) ...[
            const SizedBox(height: 8),
            _kv('Compute', '${sim.unitsConsumed} CU'),
          ],
          if (sim.willRevert) ...[
            const SizedBox(height: 14),
            _warning(
              TibaneColors.error,
              Icons.error_outline,
              'Simulation predicts this will fail: '
              '${sim.revertReason ?? "unknown error"}',
            ),
          ],
          for (final w in sim.warnings) ...[
            const SizedBox(height: 10),
            _warning(
              w.severity == 'block'
                  ? TibaneColors.error
                  : (w.severity == 'info'
                        ? TibaneColors.textMuted
                        : TibaneColors.gold),
              w.severity == 'block'
                  ? Icons.error_outline
                  : Icons.warning_amber_rounded,
              w.message.isNotEmpty ? w.message : w.code,
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: TibaneColors.textMuted,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: blocking
                      ? null
                      : () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: TibaneColors.orange,
                    foregroundColor: TibaneColors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    blocking ? 'Cannot send' : 'Confirm',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(
            k,
            style: const TextStyle(color: TibaneColors.textMuted, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: monoStyle(fontSize: 12, color: TibaneColors.text),
          ),
        ),
      ],
    );
  }

  Widget _warning(Color color, IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(color: color, fontSize: 12)),
        ),
      ],
    );
  }
}

/// Tap target at the top of the send screen showing which token is
/// active. Acts like a dropdown — pressing it opens the picker sheet.
class _TokenSelector extends StatelessWidget {
  final String? mint;
  final String symbol;
  final String? imageUrl;
  final bool loading;
  final VoidCallback? onTap;

  const _TokenSelector({
    required this.mint,
    required this.symbol,
    required this.imageUrl,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // TokenIcon's wsolMint branch picks up the bundled sol.png; for the
    // null-mint native-SOL state we hand it wsolMint so the same logo
    // wins, rather than the letter-S placeholder.
    final iconMint = mint ?? wsolMint;
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: onTap,
      child: Row(
        children: [
          TokenIcon(
            imageUrl: imageUrl,
            mint: iconMint,
            symbol: symbol,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TOKEN',
                  style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
                ),
                const SizedBox(height: 2),
                Text(
                  symbol,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          if (loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: TibaneColors.textMuted,
              ),
            )
          else
            const Icon(
              Icons.keyboard_arrow_down,
              size: 22,
              color: TibaneColors.textMuted,
            ),
        ],
      ),
    );
  }
}

/// Bottom-sheet list of tokens the user can send. Always renders a
/// native SOL row at the top (built from [solBalance]) followed by the
/// SPL holdings returned by Jupiter. Tapping a row reports the picked
/// token via [onSelect].
class _SendTokenPicker extends StatelessWidget {
  final List<TokenHolding> holdings;
  final bool loading;
  final BigInt solBalance;
  final String? selectedMint;

  /// `mint` is null for the native SOL row, the SPL mint otherwise.
  final void Function(
    String? mint,
    String symbol,
    int decimals,
    String? imageUrl,
  )
  onSelect;

  const _SendTokenPicker({
    required this.holdings,
    required this.loading,
    required this.solBalance,
    required this.selectedMint,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Text(
                  'Select token to send',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: holdings.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _row(
                    mint: null,
                    symbol: 'SOL',
                    name: 'Solana',
                    imageUrl: null,
                    iconMint: wsolMint,
                    decimals: 9,
                    uiBalance: solBalance.toDouble() / 1e9,
                    valueUsd: null,
                    selected: selectedMint == null,
                  );
                }
                final h = holdings[index - 1];
                return _row(
                  mint: h.mint,
                  symbol: h.symbol.isNotEmpty ? h.symbol : h.name,
                  name: h.name,
                  imageUrl: h.imageUrl,
                  iconMint: h.mint,
                  decimals: h.decimals,
                  uiBalance: h.uiBalance,
                  valueUsd: h.valueUsd,
                  selected: selectedMint == h.mint,
                );
              },
            ),
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: TibaneColors.textMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row({
    required String? mint,
    required String symbol,
    required String name,
    required String? imageUrl,
    required String iconMint,
    required int decimals,
    required double uiBalance,
    required double? valueUsd,
    required bool selected,
  }) {
    return ListTile(
      leading: TokenIcon(
        imageUrl: imageUrl,
        mint: iconMint,
        symbol: symbol,
        size: 36,
      ),
      title: Row(
        children: [
          Text(
            symbol,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (selected) ...[
            const SizedBox(width: 6),
            const Icon(Icons.check, size: 14, color: TibaneColors.cyan),
          ],
        ],
      ),
      subtitle: name.isNotEmpty && name != symbol
          ? Text(
              name,
              style: const TextStyle(
                color: TibaneColors.textMuted,
                fontSize: 12,
              ),
            )
          : null,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _formatBalance(uiBalance),
            style: monoStyle(fontSize: 12),
          ),
          if (valueUsd != null)
            Text(
              '\$${valueUsd.toStringAsFixed(2)}',
              style: monoStyle(fontSize: 10, color: TibaneColors.textMuted),
            ),
        ],
      ),
      onTap: () => onSelect(mint, symbol, decimals, imageUrl),
    );
  }

  String _formatBalance(double balance) {
    if (balance >= 1e6) return '${(balance / 1e6).toStringAsFixed(2)}M';
    if (balance >= 1e3) return '${(balance / 1e3).toStringAsFixed(2)}K';
    if (balance >= 1) return balance.toStringAsFixed(4);
    return balance.toStringAsFixed(6);
  }
}
