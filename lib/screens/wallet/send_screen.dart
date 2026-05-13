import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show Amount, TransactionSimulation;
import 'package:provider/provider.dart';

import '../../constants/solana_constants.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import 'inapp_unlock_screen.dart';

class SendScreen extends StatefulWidget {
  const SendScreen({super.key});

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

  @override
  void initState() {
    super.initState();
    _addrCtrl.addListener(_onAddrChanged);
  }

  @override
  void dispose() {
    _addrCtrl.removeListener(_onAddrChanged);
    _resolveDebounce?.cancel();
    _addrCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  void _onAddrChanged() {
    final raw = _addrCtrl.text.trim();
    // Only resolve when the input looks like a name (contains a dot and
    // isn't already a base58/0x-shaped address). Solana addresses are
    // 32-44 chars and don't contain dots, so a "." is a robust signal.
    final looksLikeName = raw.contains('.') &&
        !raw.startsWith('0x') &&
        raw.length < 64;
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
      );
      if (!mounted) return;
      // result.max is an Amount with lamports
      final sol = result.max.toDouble();
      _amountCtrl.text = sol.toStringAsFixed(9).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not compute max: $e');
    }
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
    final lamports = BigInt.from((amountFloat * 1e9).round());
    final amount = Amount(lamports, 9);

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
      sim = await wallet.libwallet.simulateSend(to: addr, amount: amount);
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
      final tx = await wallet.libwallet.send(to: addr, amount: amount);
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
    double amountSol,
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
        amountSol: amountSol,
        sim: sim,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Send SOL')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                            final clip = await Clipboard.getData('text/plain');
                            if (clip?.text != null) _addrCtrl.text = clip!.text!;
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
                          color: TibaneColors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ] else if (_resolvedAddress != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.check_circle,
                        color: TibaneColors.cyan, size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _resolvedAddress!,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                            fontSize: 12, color: TibaneColors.textMuted),
                      ),
                    ),
                  ],
                ),
              ] else if (_resolveError != null) ...[
                const SizedBox(height: 6),
                Text(
                  _resolveError!,
                  style: const TextStyle(
                      color: TibaneColors.error, fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _amountCtrl,
                enabled: !_sending,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Amount (SOL)',
                  suffixIcon: TextButton(
                    onPressed: _sending ? null : _setMax,
                    child: const Text('MAX', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: TibaneColors.error, fontSize: 13)),
              ],
              if (_successHash != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.check_circle, color: TibaneColors.cyan, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Sent!', style: TextStyle(color: TibaneColors.cyan, fontWeight: FontWeight.w600)),
                          Text(
                            shortenAddress(_successHash!, chars: 12),
                            style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
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
    );
  }
}

/// Pre-broadcast review of an outgoing transfer. Surfaces what libwallet's
/// `Transaction:simulate` predicts (will-revert flag, recipient rent, etc.)
/// before the user is asked to authenticate the send.
class _SendReviewSheet extends StatelessWidget {
  final String to;
  final double amountSol;
  final TransactionSimulation sim;

  const _SendReviewSheet({
    required this.to,
    required this.amountSol,
    required this.sim,
  });

  @override
  Widget build(BuildContext context) {
    final shortTo = to.length > 14
        ? '${to.substring(0, 6)}…${to.substring(to.length - 6)}'
        : to;
    final blocking = sim.willRevert ||
        sim.warnings.any((w) => w.severity == 'block');
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
          _kv('Amount', '${amountSol.toStringAsFixed(9)
              .replaceAll(RegExp(r'0+$'), '')
              .replaceAll(RegExp(r'\.$'), '')} SOL'),
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
                  onPressed: blocking ? null : () => Navigator.pop(context, true),
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
          child: Text(v, style: monoStyle(fontSize: 12, color: TibaneColors.text)),
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
