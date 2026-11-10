import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../widgets/gradient_button.dart';
import '../../utils/context_extensions.dart';

/// Optional prompt to protect legacy wallet keys with device biometrics.
/// Skipping only changes when the prompt appears, not the stored keys.
class BiometricMigrationScreen extends StatefulWidget {
  const BiometricMigrationScreen({
    super.key,
    required this.onDone,
    required this.onSkip,
  });

  /// Return to the wallet after securing it or saving the skip preference.
  final VoidCallback onDone;
  final Future<void> Function(bool dontShowAgain) onSkip;

  @override
  State<BiometricMigrationScreen> createState() =>
      _BiometricMigrationScreenState();
}

enum _Action { secure, skip }

class _BiometricMigrationScreenState extends State<BiometricMigrationScreen> {
  _Action? _action;
  bool _dontShowAgain = false;
  String? _error;

  Future<void> _secure() async {
    if (_action != null) return;
    setState(() {
      _action = _Action.secure;
      _error = null;
    });
    try {
      final ok = await context
          .read<WalletService>()
          .libwallet
          .migrateToBiometricV1();
      if (!mounted) return;
      if (ok) {
        widget.onDone();
        return;
      }
      setState(() => _error = context.l10n.bioMigPartialError);
    } catch (e) {
      logError('[BiometricMigration._secure] migrate to biometric error: $e');
      if (!mounted) return;
      setState(() => _error = walletErrorMessageForContext(context, e));
    } finally {
      if (mounted) setState(() => _action = null);
    }
  }

  Future<void> _skip() async {
    if (_action != null) return;
    setState(() {
      _action = _Action.skip;
      _error = null;
    });
    try {
      await widget.onSkip(_dontShowAgain);
      if (mounted) widget.onDone();
    } catch (e) {
      logError('[BiometricMigration._skip] save reminder error: $e');
      if (!mounted) return;
      if (!_dontShowAgain) {
        widget.onDone();
        return;
      }
      setState(() => _error = context.l10n.bioMigPreferenceSaveError);
    } finally {
      if (mounted) setState(() => _action = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = context.textTheme.headlineSmall;
    final body = context.textTheme.bodyMedium;
    const padding = EdgeInsets.all(24);
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: TibaneColors.black,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: padding,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: math.max(
                    0,
                    constraints.maxHeight - padding.vertical,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox.shrink(),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Icon(
                          Icons.fingerprint,
                          size: 64,
                          color: TibaneColors.gold,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          l10n.bioMigTitle,
                          textAlign: TextAlign.center,
                          style: title?.copyWith(
                            fontSize: (title.fontSize ?? 24) * 1.10,
                            letterSpacing: 0,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.bioMigBody,
                          textAlign: TextAlign.center,
                          style: body?.copyWith(
                            color: TibaneColors.textMuted,
                            fontSize: (body.fontSize ?? 14) * 1.15,
                            height: 1.4,
                            letterSpacing: 0,
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: TibaneColors.error,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 24),
                        GradientButton(
                          label: l10n.bioMigButton,
                          loading: _action == _Action.secure,
                          expanded: true,
                          onPressed: _action == null ? _secure : null,
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: TibaneColors.surface,
                            foregroundColor: TibaneColors.text,
                            minimumSize: const Size(0, 48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: _action == null ? _skip : null,
                          child: Text(l10n.bioMigNotNow),
                        ),
                        const SizedBox(height: 4),
                        CheckboxListTile(
                          value: _dontShowAgain,
                          title: Text(l10n.bioMigDontShowAgain),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: _action == null
                              ? (value) => setState(
                                  () => _dontShowAgain = value == true,
                                )
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
