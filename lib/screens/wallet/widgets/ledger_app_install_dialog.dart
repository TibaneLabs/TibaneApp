import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../services/hardware/hardware_wallet_service.dart';
import '../../../theme/tibane_theme.dart';
import 'hardware_status.dart';

/// A Ledger management step, for a person.
String ledgerProgressText(BuildContext context, LedgerProgress p) {
  final l10n = context.l10n;
  final percent = ((p.progress ?? 0) * 100).clamp(0, 100).round();
  if (p.type == 'permissionRequested') return l10n.hwLedgerProgressAllow;
  if (p.type == 'warning' && p.message != null) return p.message!;
  return switch (p.op) {
    'install' => l10n.hwLedgerProgressInstalling(p.app ?? '', percent),
    'uninstall' => l10n.hwLedgerProgressRemoving(p.app ?? ''),
    'genuine' => l10n.hwLedgerProgressGenuine,
    'firmware' || 'flash' => l10n.hwLedgerProgressFirmware(percent),
    _ => l10n.hwLedgerProgressWorking,
  };
}

/// Ask whether to install the Ledger app [app] and install it on a yes,
/// showing the device's progress. [missing]: an operation needs the app and
/// the device lacks it (the wording says so). Resolves true once installed.
Future<bool> showLedgerAppInstallDialog(
  BuildContext context,
  HardwareWalletService hw,
  String app, {
  bool missing = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LedgerAppInstallDialog(hw: hw, app: app, missing: missing),
  );
  return ok ?? false;
}

class _LedgerAppInstallDialog extends StatefulWidget {
  const _LedgerAppInstallDialog({
    required this.hw,
    required this.app,
    required this.missing,
  });

  final HardwareWalletService hw;
  final String app;
  final bool missing;

  @override
  State<_LedgerAppInstallDialog> createState() =>
      _LedgerAppInstallDialogState();
}

class _LedgerAppInstallDialogState extends State<_LedgerAppInstallDialog> {
  StreamSubscription<LedgerProgress>? _sub;
  LedgerProgress? _progress;
  bool _busy = false;
  String? _error;

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = null;
    });
    _sub ??= widget.hw.ledgerProgress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
    try {
      await widget.hw.installLedgerApp(widget.app);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = isHardwareDecline(e) ? null : hardwareErrorText(context, e);
      });
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final progress = _progress;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.hwLedgerInstallTitle(widget.app)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.missing
                  ? l10n.hwLedgerInstallMissingBody(widget.app)
                  : l10n.hwLedgerInstallBody,
              style: const TextStyle(height: 1.4),
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: progress?.type == 'progress' ? progress?.progress : null,
              ),
              const SizedBox(height: 8),
              Text(
                progress == null
                    ? l10n.hwLedgerProgressWorking
                    : ledgerProgressText(context, progress),
                style: const TextStyle(color: TibaneColors.textMuted),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: TibaneColors.orange)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: _busy ? null : _install,
            child: Text(l10n.hwLedgerInstall),
          ),
        ],
      ),
    );
  }
}
