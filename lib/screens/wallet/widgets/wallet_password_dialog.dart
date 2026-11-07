import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../l10n/l10n.dart';
import '../../../theme/tibane_theme.dart';

Future<String?> showWalletPasswordDialog(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (_) => const _WalletPasswordDialog(),
    );

class _WalletPasswordDialog extends StatefulWidget {
  const _WalletPasswordDialog();

  @override
  State<_WalletPasswordDialog> createState() => _WalletPasswordDialogState();
}

class _WalletPasswordDialogState extends State<_WalletPasswordDialog>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _controller.clear();
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      _cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_finishing || _controller.text.isEmpty) return;
    _finishing = true;
    final password = _controller.text;
    _controller.clear();
    Navigator.of(context).pop(password);
  }

  void _cancel() {
    if (_finishing) return;
    _finishing = true;
    _controller.clear();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final titleStyle =
        theme.dialogTheme.titleTextStyle ??
        theme.textTheme.headlineSmall ??
        const TextStyle(fontSize: 24, fontWeight: FontWeight.w400);
    return AlertDialog(
      key: const Key('wallet-password-dialog'),
      backgroundColor: TibaneColors.card,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      constraints: const BoxConstraints(maxWidth: 420),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      scrollable: true,
      title: Text(
        l10n.signSheetPasswordTitle,
        key: const Key('wallet-password-title'),
        textAlign: TextAlign.center,
        // Google Fonts loads static variants; select the actual medium file.
        style: GoogleFonts.dmSans(
          textStyle: titleStyle,
          color: TibaneColors.text,
          fontSize: (titleStyle.fontSize ?? 24) * 1.15,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ).copyWith(fontFamilyFallback: cjkFallback),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Semantics(
          label: l10n.labelPassword,
          child: TextField(
            key: const Key('wallet-password-input'),
            controller: _controller,
            obscureText: true,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      actions: [
        Row(
          children: [
            Expanded(
              child: TextButton(
                key: const Key('wallet-password-cancel'),
                onPressed: _cancel,
                style: TextButton.styleFrom(
                  foregroundColor: TibaneColors.orange,
                  minimumSize: const Size(0, 52),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                child: Text(l10n.actionCancel, textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                key: const Key('wallet-password-ok'),
                onPressed: _controller.text.isEmpty ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: TibaneColors.orange,
                  foregroundColor: TibaneColors.black,
                  minimumSize: const Size(0, 52),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Text(l10n.actionOk, textAlign: TextAlign.center),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
