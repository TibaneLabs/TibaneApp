import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/clawdwallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../utils/context_extensions.dart';

/// Polled activity feed for a single ClawdWallet.
///
/// Stage 1 polls `Crypto/ClawdWallet/<id>:activity` every ~5 s. Stage 2 will
/// hook into the realtime channel.
class ActivityScreen extends StatefulWidget {
  final String walletId;
  final String walletName;

  const ActivityScreen({
    super.key,
    required this.walletId,
    required this.walletName,
  });

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  static const _pollInterval = Duration(seconds: 5);

  Timer? _timer;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    _refresh(initial: true);
    _timer = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool initial = false}) async {
    try {
      final rows = await ClawdWalletService().activity(widget.walletId);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      logError('[Activity._refresh] load error: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (initial) _error = WalletError.from(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: Text(widget.walletName),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.l10n.clawdActivitySectionLabel,
                style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
              ),
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        color: TibaneColors.orange,
        onRefresh: () => _refresh(),
        child: _buildBody(),
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
                  context.l10n.clawdActivityLoadError,
                  style: context.textTheme.titleMedium,
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
    if (_rows.isEmpty) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                const Icon(
                  Icons.history,
                  size: 48,
                  color: TibaneColors.textDim,
                ),
                const SizedBox(height: 14),
                Text(
                  context.l10n.clawdActivityEmpty,
                  style: context.textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  context.l10n.clawdActivityEmptyHint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _ActivityRow(row: _rows[i]),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final Map<String, dynamic> row;

  const _ActivityRow({required this.row});

  String _description() {
    final intent = row['intent'];
    if (intent is Map) {
      final d = intent['description'];
      if (d is String && d.isNotEmpty) return d;
    }
    final type = row['type'];
    if (type is String && type.isNotEmpty) return type;
    return 'sign-request';
  }

  ({String? amount, String? recipient}) _effects() {
    final effects = row['parsed_effects'];
    if (effects is Map) {
      final amount = effects['amount'];
      final recipient = effects['recipient'] ?? effects['to'];
      return (amount: amount?.toString(), recipient: recipient?.toString());
    }
    return (amount: null, recipient: null);
  }

  String _status() {
    final s = row['status'];
    if (s is String && s.isNotEmpty) return s;
    if (row['approved'] == true) return 'approved';
    if (row['approved'] == false) return 'rejected';
    return 'pending';
  }

  String _timestamp() {
    final raw = row['timestamp'] ?? row['created'] ?? row['date'];
    if (raw == null) return '';
    DateTime? dt;
    if (raw is String) {
      dt = DateTime.tryParse(raw);
    } else if (raw is num) {
      dt = DateTime.fromMillisecondsSinceEpoch(
        (raw * (raw < 1e12 ? 1000 : 1)).round(),
      );
    } else if (raw is Map) {
      final iso = raw['iso'] ?? raw['date'];
      if (iso is String) dt = DateTime.tryParse(iso);
    }
    if (dt == null) return raw.toString();
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  String _truncate(String addr) {
    if (addr.length <= 12) return addr;
    return '${addr.substring(0, 6)}…${addr.substring(addr.length - 6)}';
  }

  @override
  Widget build(BuildContext context) {
    final effects = _effects();
    final status = _status();
    return TibaneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _timestamp(),
                  style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
                ),
              ),
              _StatusBadge(status: status),
            ],
          ),
          const SizedBox(height: 10),
          Text(_description(), style: context.textTheme.titleMedium),
          if (effects.amount != null || effects.recipient != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (effects.amount != null) ...[
                  const Icon(
                    Icons.south_east,
                    size: 14,
                    color: TibaneColors.gold,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    effects.amount!,
                    style: monoStyle(fontSize: 13, color: TibaneColors.gold),
                  ),
                  const SizedBox(width: 12),
                ],
                if (effects.recipient != null)
                  Expanded(
                    child: Text(
                      _truncate(effects.recipient!),
                      style: monoStyle(
                        fontSize: 12,
                        color: TibaneColors.textMuted,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final lower = status.toLowerCase();
    Color color;
    switch (lower) {
      case 'approved':
      case 'success':
      case 'signed':
      case 'completed':
        color = TibaneColors.cyan;
        break;
      case 'rejected':
      case 'denied':
      case 'failed':
        color = TibaneColors.error;
        break;
      case 'pending':
      case 'running':
        color = TibaneColors.gold;
        break;
      default:
        color = TibaneColors.textMuted;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        lower.toUpperCase(),
        style: monoStyle(fontSize: 9, color: color),
      ),
    );
  }
}
