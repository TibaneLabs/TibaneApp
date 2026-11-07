import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../services/wallet/logical_wallet.dart';
import '../../../theme/tibane_theme.dart';

/// An in-page wallet picker that keeps the selected wallet visible while open.
class WalletGroupSelector extends StatefulWidget {
  const WalletGroupSelector({
    super.key,
    required this.groups,
    required this.selectedId,
    required this.onChanged,
    this.enabled = true,
  });

  final List<LogicalWallet> groups;
  final String? selectedId;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  State<WalletGroupSelector> createState() => _WalletGroupSelectorState();
}

class _WalletGroupSelectorState extends State<WalletGroupSelector> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selected = widget.groups.firstWhere(
      (group) => group.id == widget.selectedId,
      orElse: () => widget.groups.first,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.labelWallet,
          style: const TextStyle(
            color: TibaneColors.text,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        Material(
          color: TibaneColors.darker,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: _expanded ? TibaneColors.orange : TibaneColors.border,
            ),
          ),
          child: InkWell(
            key: const Key('wallet-selector-trigger'),
            borderRadius: BorderRadius.circular(8),
            onTap: widget.enabled
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: SizedBox(
              height: 58,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(
                      Icons.account_balance_wallet_outlined,
                      color: TibaneColors.textMuted,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        selected.displayName(l10n.walletsMgmtUnnamed),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: TibaneColors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      color: TibaneColors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_expanded && widget.enabled) ...[
          const SizedBox(height: 8),
          DecoratedBox(
            key: const Key('wallet-selector-options'),
            decoration: BoxDecoration(
              color: TibaneColors.card,
              border: Border.all(color: TibaneColors.orange),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.groups.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final group = widget.groups[index];
                    final isSelected = group.id == widget.selectedId;
                    return Material(
                      color: TibaneColors.card,
                      child: InkWell(
                        onTap: () {
                          if (!isSelected) widget.onChanged(group.id);
                          setState(() => _expanded = false);
                        },
                        child: SizedBox(
                          height: 52,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    group.displayName(l10n.walletsMgmtUnnamed),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: TibaneColors.text,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  const Icon(
                                    Icons.check,
                                    color: TibaneColors.orange,
                                    size: 20,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
