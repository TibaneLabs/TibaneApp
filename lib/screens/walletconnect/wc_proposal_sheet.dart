import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show WcSessionProposal;

import '../../services/wallet/walletconnect_bridge.dart';
import '../../theme/tibane_theme.dart';

class WcSessionApproveResult {
  final List<String> accounts; // CAIP-10 strings
  const WcSessionApproveResult(this.accounts);
}

/// Bottom sheet shown when a dApp sends `wc_sessionPropose`. Lists the
/// requested chains/methods/events and lets the user pick which of their
/// libwallet accounts to expose. Returns null on cancel.
Future<WcSessionApproveResult?> showWcSessionProposalSheet(
  BuildContext context, {
  required WcSessionProposal proposal,
  required List<WcCandidateAccount> candidateAccounts,
}) {
  return showModalBottomSheet<WcSessionApproveResult>(
    context: context,
    backgroundColor: TibaneColors.card,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) =>
        _WcProposalSheet(proposal: proposal, candidates: candidateAccounts),
  );
}

class _WcProposalSheet extends StatefulWidget {
  final WcSessionProposal proposal;
  final List<WcCandidateAccount> candidates;

  const _WcProposalSheet({required this.proposal, required this.candidates});

  @override
  State<_WcProposalSheet> createState() => _WcProposalSheetState();
}

class _WcProposalSheetState extends State<_WcProposalSheet> {
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    // Default to selecting every candidate — the dApp asked for them.
    _selected = widget.candidates.map((c) => c.caip10).toSet();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final name = p.name.isNotEmpty ? p.name : '(unknown dApp)';
    final url = p.url;
    final required = p.proposal['requiredNamespaces'];
    final optional = p.proposal['optionalNamespaces'];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: TibaneColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'WalletConnect session',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              _SectionLabel('Connecting to'),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  name,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (url.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    url,
                    style: monoStyle(
                      fontSize: 11,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              if (required is Map && required.isNotEmpty) ...[
                _SectionLabel('Requested'),
                _NamespaceList(map: Map<String, dynamic>.from(required)),
                const SizedBox(height: 8),
              ],
              if (optional is Map && optional.isNotEmpty) ...[
                _SectionLabel('Optional'),
                _NamespaceList(map: Map<String, dynamic>.from(optional)),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 4),
              _SectionLabel('Accounts to expose'),
              if (widget.candidates.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'You don\'t have any accounts that match the chains '
                    'this dApp is asking for.',
                    style: monoStyle(
                      fontSize: 12,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ),
              ...widget.candidates.map((c) {
                final on = _selected.contains(c.caip10);
                final preview = c.address.length > 14
                    ? '${c.address.substring(0, 6)}…${c.address.substring(c.address.length - 6)}'
                    : c.address;
                return CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: on,
                  activeColor: TibaneColors.orange,
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(c.caip10);
                    } else {
                      _selected.remove(c.caip10);
                    }
                  }),
                  title: Text(
                    '${c.namespace.toUpperCase()} · ${c.chainId}',
                    style: monoStyle(fontSize: 12),
                  ),
                  subtitle: Text(
                    preview,
                    style: monoStyle(
                      fontSize: 11,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                );
              }),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Reject'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _selected.isEmpty
                          ? null
                          : () => Navigator.of(
                              context,
                            ).pop(WcSessionApproveResult(_selected.toList())),
                      style: FilledButton.styleFrom(
                        backgroundColor: TibaneColors.orange,
                        foregroundColor: TibaneColors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text(
                        'Approve',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 4),
    child: Text(
      text.toUpperCase(),
      style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
    ),
  );
}

class _NamespaceList extends StatelessWidget {
  final Map<String, dynamic> map;

  const _NamespaceList({required this.map});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: map.entries.map((e) {
        final ns = e.key;
        final spec = e.value is Map
            ? Map<String, dynamic>.from(e.value as Map)
            : const <String, dynamic>{};
        final chains =
            (spec['chains'] as List?)?.whereType<String>().toList() ?? const [];
        final methods =
            (spec['methods'] as List?)?.whereType<String>().toList() ??
            const [];
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ns.toUpperCase(),
                style: monoStyle(fontSize: 11, color: TibaneColors.text),
              ),
              if (chains.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'chains: ${chains.join(', ')}',
                    style: monoStyle(
                      fontSize: 10,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ),
              if (methods.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'methods: ${methods.join(', ')}',
                    style: monoStyle(
                      fontSize: 10,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
