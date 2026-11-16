import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/tibane_theme.dart';

class MpcWalletIntroScreen extends StatefulWidget {
  const MpcWalletIntroScreen({super.key});

  @override
  State<MpcWalletIntroScreen> createState() => _MpcWalletIntroScreenState();
}

class _MpcWalletIntroScreenState extends State<MpcWalletIntroScreen> {
  int _step = 0;

  void _previousStep() => setState(() => _step--);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final heading = theme.textTheme.headlineSmall;
    final appBarTitle = theme.appBarTheme.titleTextStyle;
    final steps = [
      (
        icon: Icons.key_outlined,
        title: l10n.mpcIntroSplitTitle,
        body: l10n.mpcIntroSplitBody,
        emphasis: null,
      ),
      (
        icon: Icons.notes_rounded,
        title: l10n.mpcIntroPhraseTitle,
        body: l10n.mpcIntroPhraseBody,
        emphasis: l10n.mpcIntroPhraseEmphasis,
      ),
      (
        icon: Icons.verified_user_outlined,
        title: l10n.mpcIntroSecurityTitle,
        body: l10n.mpcIntroSecurityBody,
        emphasis: l10n.mpcIntroSecurityEmphasis,
      ),
      (
        icon: Icons.backup_outlined,
        title: l10n.mpcIntroRestoreTitle,
        body: l10n.mpcIntroRestoreBody,
        emphasis: l10n.mpcIntroRestoreEmphasis,
      ),
    ];
    final current = steps[_step];
    final last = _step == steps.length - 1;

    return PopScope<bool>(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step > 0) _previousStep();
      },
      child: Scaffold(
        backgroundColor: TibaneColors.black,
        appBar: AppBar(
          title: Text(
            l10n.inappCreateTitle,
            style: appBarTitle?.copyWith(
              fontSize: (appBarTitle.fontSize ?? 20) * 1.15,
            ),
          ),
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: Semantics(
                  label: l10n.mpcIntroProgress(_step + 1, steps.length),
                  child: Row(
                    children: [
                      for (var i = 0; i < steps.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            height: 4,
                            decoration: BoxDecoration(
                              color: i <= _step
                                  ? TibaneColors.orange
                                  : TibaneColors.border,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  key: ValueKey(_step),
                  padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
                  child: Column(
                    children: [
                      Icon(current.icon, size: 64, color: TibaneColors.orange),
                      const SizedBox(height: 24),
                      Semantics(
                        header: true,
                        child: Text(
                          current.title,
                          textAlign: TextAlign.center,
                          style: heading?.copyWith(
                            fontSize: (heading.fontSize ?? 24) * 1.15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text.rich(
                        TextSpan(
                          text: current.body,
                          children: [
                            if (current.emphasis case final emphasis?) ...[
                              const TextSpan(text: '\n\n'),
                              TextSpan(
                                text: emphasis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: TibaneColors.textMuted,
                          fontSize: 18,
                          height: 1.55,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton(
                      key: const Key('mpc-intro-next'),
                      onPressed: last
                          ? () => Navigator.of(context).pop(true)
                          : () => setState(() => _step++),
                      style: FilledButton.styleFrom(
                        backgroundColor: TibaneColors.orange,
                        foregroundColor: TibaneColors.black,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                      child: Text(
                        last ? l10n.mpcIntroStart : l10n.actionNext,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      key: const Key('mpc-intro-back'),
                      onPressed: _step == 0
                          ? () => Navigator.of(context).pop()
                          : _previousStep,
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
      ),
    );
  }
}
