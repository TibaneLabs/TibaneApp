import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../services/ledger/ledger_transport.dart';
import '../../../theme/tibane_theme.dart';
import 'hardware_status.dart';

/// Let the person pick a Ledger — over USB-OTG (Android) or Bluetooth — and
/// open it. Resolves true once [LedgerConnector.current] is open.
Future<bool> showLedgerConnectSheet(
  BuildContext context,
  LedgerConnector connector,
) async {
  final current = connector.current;
  if (current != null && current.isOpen) return true;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _LedgerConnectSheet(connector: connector),
  );
  return ok ?? false;
}

class _LedgerConnectSheet extends StatefulWidget {
  const _LedgerConnectSheet({required this.connector});

  final LedgerConnector connector;

  @override
  State<_LedgerConnectSheet> createState() => _LedgerConnectSheetState();
}

class _LedgerConnectSheetState extends State<_LedgerConnectSheet> {
  List<LedgerDeviceInfo> _usb = const [];
  List<LedgerDeviceInfo> _ble = const [];
  StreamSubscription<List<LedgerDeviceInfo>>? _scan;
  bool _searching = false;
  String? _connectingId;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  Future<void> _search() async {
    await _scan?.cancel();
    setState(() {
      _searching = true;
      _error = null;
      _usb = const [];
      _ble = const [];
    });
    final connector = widget.connector;
    try {
      if (await connector.usbSupported) {
        final usb = await connector.listUsb();
        if (!mounted) return;
        setState(() => _usb = usb);
        // One Ledger on USB is the usual case: connect straight away.
        if (usb.length == 1) {
          unawaited(_connect(usb.first));
          return;
        }
      }
    } on LedgerException catch (e) {
      if (mounted) setState(() => _error = ledgerErrorText(context, e));
    }
    try {
      if (await connector.bleSupported) {
        _scan = connector
            .scanBle(timeout: const Duration(seconds: 12))
            .listen(
              (found) {
                if (mounted) setState(() => _ble = found);
              },
              onError: (Object e) {
                if (!mounted) return;
                setState(() {
                  _error = e is LedgerException
                      ? ledgerErrorText(context, e)
                      : '$e';
                  _searching = false;
                });
              },
              onDone: () {
                if (mounted) setState(() => _searching = false);
              },
            );
        return;
      }
    } on LedgerException catch (e) {
      if (mounted) setState(() => _error = ledgerErrorText(context, e));
    }
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _connect(LedgerDeviceInfo device) async {
    setState(() {
      _connectingId = device.id;
      _error = null;
    });
    try {
      await widget.connector.stopScan();
      await widget.connector.open(device);
      if (mounted) Navigator.of(context).pop(true);
    } on LedgerException catch (e) {
      if (mounted) setState(() => _error = ledgerErrorText(context, e));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  @override
  void dispose() {
    unawaited(_scan?.cancel());
    unawaited(widget.connector.stopScan());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final devices = [..._usb, ..._ble];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.hwLedgerConnectTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              l10n.hwLedgerSteps,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: TibaneColors.textMuted,
              ),
            ),
            const SizedBox(height: 16),
            for (final d in devices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  d.kind == 'usb' ? Icons.usb : Icons.bluetooth,
                  color: TibaneColors.text,
                ),
                title: Text(d.name),
                trailing: _connectingId == d.id
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: _connectingId == null ? () => _connect(d) : null,
              ),
            if (devices.isEmpty && _searching)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  children: [
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(l10n.hwLedgerScanning)),
                  ],
                ),
              ),
            if (devices.isEmpty && !_searching && _error == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  l10n.hwLedgerNoneFound,
                  style: const TextStyle(color: TibaneColors.textMuted),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: TibaneColors.orange),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l10n.actionCancel),
                ),
                const Spacer(),
                if (!_searching)
                  TextButton.icon(
                    onPressed: _connectingId == null ? _search : null,
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.hwLedgerSearchAgain),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
