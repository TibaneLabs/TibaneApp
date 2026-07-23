import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../services/wallet/logical_wallet.dart';
import '../../../services/wallet/unified_account.dart';
import '../../../services/wallet_service.dart';
import '../../../theme/tibane_theme.dart';
import 'account_avatar.dart';
import 'account_switcher_view_model.dart';

/// Result of the add-account form: the wallet + chain to create on, the account
/// name, and the chosen avatar. The dialog pops null when cancelled.
class AddAccountResult {
  final String walletId;
  final String chain;
  final String name;
  final String avatarAsset;

  const AddAccountResult({
    required this.walletId,
    required this.chain,
    required this.name,
    required this.avatarAsset,
  });
}

/// The add-account dialog: pick a logical wallet + a creatable chain, name the
/// account, and choose an avatar. Pops an [AddAccountResult] on create.
class AddAccountDialog extends StatefulWidget {
  final WalletService wallet;
  final UnifiedAccount target;
  final List<LogicalWallet> groups;
  final String initialAvatarAsset;

  const AddAccountDialog({
    super.key,
    required this.wallet,
    required this.target,
    required this.groups,
    required this.initialAvatarAsset,
  });

  @override
  State<AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<AddAccountDialog> {
  late String _selectedGroupId;
  late List<String> _selectedChains;
  late String _selectedChain;
  late String _selectedAvatarAsset;
  late final TextEditingController _nameCtrl;

  LogicalWallet get _selectedGroup => widget.groups.firstWhere(
        (group) => group.id == _selectedGroupId,
        orElse: () => widget.groups.first,
      );

  @override
  void initState() {
    super.initState();
    _selectedAvatarAsset = widget.initialAvatarAsset;
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
    final walletForChain = group.walletForChain(chain);
    if (walletForChain == null) return 0;
    return widget.wallet.accountsService.rawAccounts
        .where(
          (a) =>
              a.wallet == walletForChain.id &&
              a.type == accountTypeForChain(chain),
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
        avatarAsset: _selectedAvatarAsset,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      backgroundColor: TibaneColors.card,
      title: Text(l10n.accountSwitcherAddAccount),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _selectedGroupId,
              decoration: InputDecoration(labelText: l10n.labelWallet),
              items: [
                for (final group in widget.groups)
                  DropdownMenuItem(
                    value: group.id,
                    child: Text(group.displayName(l10n.walletsMgmtUnnamed)),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                _selectGroup(v);
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: ValueKey(_selectedGroupId),
              initialValue: _selectedChain,
              decoration: InputDecoration(labelText: l10n.labelNetwork),
              items: [
                for (final chain in _selectedChains)
                  DropdownMenuItem(
                      value: chain, child: Text(chainLabel(chain))),
              ],
              onChanged: (v) {
                if (v == null) return;
                _selectChain(v);
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: l10n.accountSwitcherAccountName,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            AccountAvatarSelector(
              label: l10n.accountSwitcherAvatar,
              selectedAsset: _selectedAvatarAsset,
              onSelected: (asset) {
                if (!mounted) return;
                setState(() => _selectedAvatarAsset = asset);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.actionCancel),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(
            l10n.actionCreate,
            style: const TextStyle(color: TibaneColors.orange),
          ),
        ),
      ],
    );
  }
}
