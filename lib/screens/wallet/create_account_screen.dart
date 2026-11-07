import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/logical_wallet.dart';
import '../../services/wallet/unified_account.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import 'widgets/account_switcher_view_model.dart';
import 'widgets/wallet_group_selector.dart';

/// Result of the add-account form: the wallet + chain to create on and the
/// account name. The screen pops null when cancelled.
class AddAccountResult {
  final String walletId;
  final String chain;
  final String name;

  const AddAccountResult({
    required this.walletId,
    required this.chain,
    required this.name,
  });
}

/// Pick a logical wallet and chain for a new derived account.
class CreateAccountScreen extends StatefulWidget {
  final WalletService wallet;
  final UnifiedAccount target;
  final List<LogicalWallet> groups;

  const CreateAccountScreen({
    super.key,
    required this.wallet,
    required this.target,
    required this.groups,
  });

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  late String _selectedGroupId;
  late List<String> _selectedChains;
  late String _selectedChain;
  late final TextEditingController _nameCtrl;

  LogicalWallet get _selectedGroup => widget.groups.firstWhere(
    (group) => group.id == _selectedGroupId,
    orElse: () => widget.groups.first,
  );

  @override
  void initState() {
    super.initState();
    _selectedGroupId = widget.groups
        .firstWhere(
          (group) =>
              widget.target.walletId != null &&
              group.containsWallet(widget.target.walletId!),
          orElse: () => widget.groups.first,
        )
        .id;
    _selectedChains = creationChains(_selectedGroup);
    _selectedChain = initialChain(_selectedChains, widget.target.chain);
    _nameCtrl = TextEditingController(text: _suggestName());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  int _existingCount(LogicalWallet group, String chain) {
    return widget.wallet.accounts
        .where(
          (account) =>
              account.isInApp &&
              account.walletId != null &&
              group.containsWallet(account.walletId!) &&
              account.chain == chain &&
              !account.isVirtual,
        )
        .length;
  }

  String _suggestName() =>
      suggestAccountName(_existingCount(_selectedGroup, _selectedChain));

  void _selectGroup(String groupId) {
    setState(() {
      _selectedGroupId = groupId;
      _selectedChains = creationChains(_selectedGroup);
      _selectedChain = initialChain(_selectedChains, _selectedChain);
      _nameCtrl.text = _suggestName();
    });
  }

  void _selectChain(String chain) {
    setState(() {
      _selectedChain = chain;
      _nameCtrl.text = _suggestName();
    });
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final walletForChain = _selectedGroup.walletForChain(_selectedChain);
    if (name.isEmpty || walletForChain == null) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(
      context,
      AddAccountResult(
        walletId: walletForChain.id,
        chain: _selectedChain,
        name: name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const fieldStyle = TextStyle(
      color: TibaneColors.text,
      fontSize: 18,
      fontWeight: FontWeight.w600,
    );
    const labelStyle = TextStyle(
      color: TibaneColors.text,
      fontSize: 18,
      fontWeight: FontWeight.w600,
    );
    const fieldPadding = EdgeInsets.symmetric(horizontal: 18, vertical: 18);

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.accountAddCreateTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            WalletGroupSelector(
              groups: widget.groups,
              selectedId: _selectedGroupId,
              onChanged: _selectGroup,
            ),
            const SizedBox(height: 22),
            Text(l10n.labelChain, style: labelStyle),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  for (final chain in _selectedChains)
                    ButtonSegment(
                      value: chain,
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 22,
                            child: chain == _selectedChain
                                ? const Icon(Icons.check, size: 18)
                                : null,
                          ),
                          const SizedBox(width: 4),
                          Text(chainLabel(chain)),
                        ],
                      ),
                    ),
                ],
                selected: {_selectedChain},
                onSelectionChanged: (selection) =>
                    _selectChain(selection.first),
              ),
            ),
            const SizedBox(height: 22),
            Text(l10n.accountSwitcherAccountName, style: labelStyle),
            const SizedBox(height: 10),
            TextField(
              controller: _nameCtrl,
              maxLines: 1,
              style: fieldStyle,
              decoration: const InputDecoration(contentPadding: fieldPadding),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(
                backgroundColor: TibaneColors.orange,
                foregroundColor: TibaneColors.black,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(l10n.actionCreate),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                backgroundColor: TibaneColors.darker,
                foregroundColor: TibaneColors.textMuted,
                side: const BorderSide(color: TibaneColors.border),
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(l10n.actionCancel),
            ),
          ],
        ),
      ),
    );
  }
}
