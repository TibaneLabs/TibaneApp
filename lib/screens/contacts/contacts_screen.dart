import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/wallet_error_display.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../utils/context_extensions.dart';

/// Contacts CRUD — backed by libwallet's `Contact` API. List → tap to
/// edit, swipe / button to delete, FAB to add. Recipient autocomplete in
/// Send/Swap is a separate task.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<lw.Contact>? _contacts;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final client = await context
          .read<WalletService>()
          .libwallet
          .ensureClient();
      final list = await client.contacts.list();
      if (!mounted) return;
      setState(() {
        _contacts = list;
        _loading = false;
      });
    } catch (e) {
      logError('[Contacts._load] load error: $e');
      if (!mounted) return;
      setState(() {
        _error = WalletError.from(e).message;
        _loading = false;
      });
    }
  }

  Future<void> _add() async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const _ContactEditScreen()));
    if (saved == true) _load();
  }

  Future<void> _edit(lw.Contact c) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _ContactEditScreen(initial: c)),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(lw.Contact c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l10n = ctx.l10n;
        return AlertDialog(
          backgroundColor: TibaneColors.card,
          title: Text(l10n.contactsDeleteTitle),
          content: Text(
            l10n.contactsDeleteBody(c.name),
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
                l10n.actionDelete,
                style: const TextStyle(color: TibaneColors.error),
              ),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    if (!mounted) return;
    try {
      final client = await context
          .read<WalletService>()
          .libwallet
          .ensureClient();
      await client.contacts.delete(c.id);
      _load();
    } catch (e) {
      logError('[Contacts._delete] delete error: $e');
      if (!mounted) return;
      showWalletError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.contactsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: TibaneColors.orange,
        foregroundColor: TibaneColors.black,
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: Text(l10n.contactsNewContact),
      ),
      body: SafeArea(
        child: Builder(
          builder: (context) {
            if (_loading) {
              return const Center(
                child: CircularProgressIndicator(color: TibaneColors.orange),
              );
            }
            if (_error != null) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: TibaneColors.textMuted),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            final list = _contacts ?? const [];
            if (list.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.people_outline,
                        size: 48,
                        color: TibaneColors.textDim,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.contactsEmpty,
                        style: context.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.contactsEmptyHint,
                        style: const TextStyle(color: TibaneColors.textMuted),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _ContactRow(
                contact: list[i],
                onTap: () => _edit(list[i]),
                onDelete: () => _delete(list[i]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final lw.Contact contact;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ContactRow({
    required this.contact,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final addr = contact.address;
    final preview = addr.length > 14
        ? '${addr.substring(0, 6)}…${addr.substring(addr.length - 6)}'
        : addr;
    return TibaneCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const Icon(
            Icons.account_circle_outlined,
            color: TibaneColors.textMuted,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  contact.name,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${contact.type} · $preview',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
                if (contact.memo.isNotEmpty)
                  Text(
                    contact.memo,
                    style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: context.l10n.actionCopyAddress,
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: addr));
              context.showSnackBar(
                SnackBar(
                  content: Text(context.l10n.addressCopied),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
          IconButton(
            tooltip: context.l10n.actionDelete,
            icon: const Icon(Icons.delete_outline, size: 18),
            color: TibaneColors.error,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _ContactEditScreen extends StatefulWidget {
  final lw.Contact? initial;

  const _ContactEditScreen({this.initial});

  @override
  State<_ContactEditScreen> createState() => _ContactEditScreenState();
}

class _ContactEditScreenState extends State<_ContactEditScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _memoCtrl;
  String _type = 'solana';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    _nameCtrl = TextEditingController(text: c?.name ?? '');
    _addressCtrl = TextEditingController(text: c?.address ?? '');
    _memoCtrl = TextEditingController(text: c?.memo ?? '');
    if (c != null && c.type.isNotEmpty) _type = c.type;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _memoCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final name = _nameCtrl.text.trim();
    final address = _addressCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.contactsNameRequired);
      return;
    }
    if (address.isEmpty) {
      setState(() => _error = l10n.contactsAddressRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = await context
          .read<WalletService>()
          .libwallet
          .ensureClient();
      if (widget.initial == null) {
        await client.contacts.create(
          name: name,
          address: address,
          type: _type,
          memo: _memoCtrl.text.trim(),
        );
      } else {
        await client.contacts.update(
          widget.initial!.id,
          name: name,
          address: address,
          type: _type,
          memo: _memoCtrl.text.trim(),
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      logError('[Contacts._save] save error: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = WalletError.from(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isNew = widget.initial == null;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: Text(isNew ? l10n.contactsNewContact : l10n.contactsEditContact),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ListView(
            children: [
              TextField(
                controller: _nameCtrl,
                enabled: !_busy,
                decoration: InputDecoration(labelText: l10n.labelName),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _addressCtrl,
                enabled: !_busy,
                autocorrect: false,
                decoration: InputDecoration(labelText: l10n.labelAddress),
                style: monoStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: InputDecoration(labelText: l10n.labelType),
                items: const [
                  DropdownMenuItem(value: 'solana', child: Text('Solana')),
                  DropdownMenuItem(
                    value: 'ethereum',
                    child: Text('Ethereum / EVM'),
                  ),
                  DropdownMenuItem(value: 'bitcoin', child: Text('Bitcoin')),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _type = v ?? _type),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _memoCtrl,
                enabled: !_busy,
                maxLines: 2,
                decoration: InputDecoration(labelText: l10n.contactsMemoLabel),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: TibaneColors.error),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: TibaneColors.orange,
                  foregroundColor: TibaneColors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  _busy
                      ? l10n.contactsSaving
                      : (isNew ? l10n.actionCreate : l10n.contactsSaveChanges),
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
