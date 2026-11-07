import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/context_extensions.dart';
import 'inapp_export_screen.dart';

bool walletResetConfirmationMatches(String input, String expected) =>
    input.trim().toLowerCase() == expected.trim().toLowerCase();

class WalletDataResetScreen extends StatefulWidget {
  const WalletDataResetScreen({super.key});

  @override
  State<WalletDataResetScreen> createState() => _WalletDataResetScreenState();
}

class _WalletDataResetScreenState extends State<WalletDataResetScreen> {
  final _confirmationController = TextEditingController();
  int _step = 0;
  bool _busy = false;
  bool _completed = false;
  String? _error;

  Future<void> _openBackup() async {
    if (_busy) return;
    _confirmationController.clear();
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const InAppExportScreen()));
    if (!mounted) return;
    setState(() => _error = null);
  }

  @override
  void dispose() {
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _removeAllWallets() async {
    if (_busy) return;
    final l10n = context.l10n;
    if (!walletResetConfirmationMatches(
      _confirmationController.text,
      l10n.walletResetConfirmationWord,
    )) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await context.read<WalletService>().removeAllWalletsFromDevice();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _completed = ok;
      if (!ok) _error = l10n.walletResetFailure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final titleStyle = context.textTheme.headlineSmall?.copyWith(
      fontSize: (context.textTheme.headlineSmall?.fontSize ?? 24) * 1.15,
      fontWeight: FontWeight.w700,
    );
    final appBarStyle = Theme.of(context).appBarTheme.titleTextStyle;
    final enlargedAppBarStyle = appBarStyle?.copyWith(
      fontSize: (appBarStyle.fontSize ?? 20) * 1.15,
    );
    const bodyStyle = TextStyle(
      color: TibaneColors.textMuted,
      fontSize: 15 * 1.2,
      height: 1.55,
    );
    if (_completed) {
      return Scaffold(
        backgroundColor: TibaneColors.black,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(l10n.walletResetTitle, style: enlargedAppBarStyle),
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 48).clamp(
                    0.0,
                    double.infinity,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      color: TibaneColors.cyan,
                      size: 72,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l10n.walletResetSuccessTitle,
                      textAlign: TextAlign.center,
                      style: titleStyle,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.walletResetSuccessBody,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: TibaneColors.textMuted,
                        fontSize: 14 * 1.2,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.of(
                          context,
                        ).popUntil((route) => route.isFirst),
                        style: FilledButton.styleFrom(
                          backgroundColor: TibaneColors.orange,
                          foregroundColor: TibaneColors.black,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        child: Text(l10n.actionDone),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final steps = [
      (
        icon: Icons.delete_forever_outlined,
        title: l10n.walletResetStepOneTitle,
        body: l10n.walletResetStepOneBody,
      ),
      (
        icon: Icons.account_balance_outlined,
        title: l10n.walletResetStepTwoTitle,
        body: l10n.walletResetStepTwoBody,
      ),
      (
        icon: Icons.backup_outlined,
        title: l10n.walletResetStepThreeTitle,
        body: l10n.walletResetStepThreeBody,
      ),
      (
        icon: Icons.warning_amber_rounded,
        title: l10n.walletResetFinalTitle,
        body: l10n.walletResetFinalBody(l10n.walletResetConfirmationWord),
      ),
    ];
    final current = steps[_step];
    final isFinal = _step == steps.length - 1;
    final confirmed = walletResetConfirmationMatches(
      _confirmationController.text,
      l10n.walletResetConfirmationWord,
    );

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: Text(l10n.walletResetTitle, style: enlargedAppBarStyle),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Row(
                children: [
                  for (var i = 0; i < steps.length; i++) ...[
                    Expanded(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        height: 4,
                        decoration: BoxDecoration(
                          color: i <= _step
                              ? TibaneColors.error
                              : TibaneColors.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    if (i < steps.length - 1) const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
                child: Column(
                  children: [
                    Icon(current.icon, size: 64, color: TibaneColors.error),
                    const SizedBox(height: 24),
                    Text(
                      current.title,
                      textAlign: TextAlign.center,
                      style: titleStyle,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      current.body,
                      textAlign: TextAlign.center,
                      style: bodyStyle,
                    ),
                    if (isFinal) ...[
                      const SizedBox(height: 20),
                      Text(
                        l10n.walletResetAgreement,
                        textAlign: TextAlign.center,
                        style: bodyStyle,
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _confirmationController,
                        enabled: !_busy,
                        textInputAction: TextInputAction.done,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) {
                          if (confirmed) _removeAllWallets();
                        },
                        decoration: InputDecoration(
                          labelText: l10n.walletResetConfirmationLabel,
                          hintText: l10n.walletResetConfirmationWord,
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 18),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: TibaneColors.error,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                children: [
                  if (_step == 2) ...[
                    TextButton(
                      key: const Key('wallet-reset-backup'),
                      onPressed: _busy ? null : _openBackup,
                      style: TextButton.styleFrom(
                        foregroundColor: TibaneColors.orange,
                      ),
                      child: Text(
                        l10n.walletResetBackupAction,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy || (isFinal && !confirmed)
                          ? null
                          : isFinal
                          ? _removeAllWallets
                          : () => setState(() => _step++),
                      style: FilledButton.styleFrom(
                        backgroundColor: isFinal
                            ? TibaneColors.error
                            : TibaneColors.orange,
                        foregroundColor: isFinal
                            ? Colors.white
                            : TibaneColors.black,
                        disabledBackgroundColor: TibaneColors.card,
                        disabledForegroundColor: TibaneColors.textDim,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                      child: _busy
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(l10n.walletResetRemoving),
                              ],
                            )
                          : Text(
                              isFinal
                                  ? l10n.walletResetRemoveAction
                                  : l10n.actionNext,
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : _step == 0
                        ? () => Navigator.of(context).pop()
                        : () => setState(() {
                            _step--;
                            _error = null;
                          }),
                    child: Text(
                      _step == 0 ? l10n.actionCancel : l10n.actionBack,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
