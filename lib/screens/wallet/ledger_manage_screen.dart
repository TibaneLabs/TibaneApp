import 'dart:async';

import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show LedgerApp, LedgerFirmwareUpdate;
import 'package:libwallet/libwallet.dart' as lw show LedgerStatus;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/hardware/hardware_wallet_service.dart';
import '../../services/ledger/ledger_transport.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/context_extensions.dart';
import '../../widgets/tibane_card.dart';
import 'widgets/hardware_status.dart';
import 'widgets/ledger_app_install_dialog.dart';
import 'widgets/ledger_connect_sheet.dart';

/// Where a firmware update stands on this screen.
enum _UpdateStage {
  none,

  /// The updater is installed and the device restarts into it (it installs
  /// the update by itself).
  restarting,

  /// The device restarts in bootloader mode: the MCU / bootloader is flashed
  /// next, from here.
  bootloader,
}

/// Device management for a Ledger, through libwallet's manager routes:
/// model and firmware, firmware updates, the genuine check, and installing or
/// removing apps. Everything here needs the device on its dashboard; the
/// service closes an open app first.
class LedgerManageScreen extends StatefulWidget {
  const LedgerManageScreen({super.key, this.neededApps = const []});

  /// The apps this wallet's accounts sign with (`Solana`, `Ethereum`,
  /// `Bitcoin`), listed first.
  final List<String> neededApps;

  @override
  State<LedgerManageScreen> createState() => _LedgerManageScreenState();
}

class _LedgerManageScreenState extends State<LedgerManageScreen> {
  late final HardwareWalletService _hw = context.read<WalletService>().hardware;
  StreamSubscription<LedgerProgress>? _progressSub;

  lw.LedgerStatus? _status;
  bool? _genuine;
  List<LedgerApp>? _installed;
  List<LedgerApp>? _catalog;

  _UpdateStage _stage = _UpdateStage.none;
  LedgerFirmwareUpdate? _update;

  /// The running operation, for the progress line; null when idle.
  String? _busy;
  LedgerProgress? _progress;
  String? _error;
  String? _notice;

  List<String> get _needed => widget.neededApps.isEmpty
      ? const ['Solana', 'Ethereum', 'Bitcoin']
      : widget.neededApps;

  @override
  void initState() {
    super.initState();
    _progressSub = _hw.ledgerProgress.listen((p) {
      if (mounted && _busy != null) setState(() => _progress = p);
    });
  }

  @override
  void dispose() {
    unawaited(_progressSub?.cancel());
    super.dispose();
  }

  bool get _connected => _hw.ledger.current?.isOpen ?? false;

  /// Run [task] as the one operation in progress, with [label] as its
  /// progress line until the device reports better.
  Future<void> _run(String label, Future<void> Function() task) async {
    if (_busy != null) return;
    setState(() {
      _busy = label;
      _progress = null;
      _error = null;
      _notice = null;
    });
    try {
      if (!_connected && !await showLedgerConnectSheet(context, _hw.ledger)) {
        return;
      }
      await task();
    } catch (e) {
      if (!mounted) return;
      if (!isHardwareDecline(e)) {
        setState(() => _error = hardwareErrorText(context, e));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _connect() async {
    if (_busy != null) return;
    setState(() => _error = null);
    if (await showLedgerConnectSheet(context, _hw.ledger)) {
      await _checkDevice();
    }
  }

  Future<void> _checkDevice() => _run(context.l10n.hwLedgerReading, () async {
    final st = await _hw.ledgerStatus();
    if (!mounted) return;
    setState(() {
      _status = st;
      if (st.bootloader) {
        _stage = _UpdateStage.bootloader;
      } else if (!st.updater) {
        _stage = _UpdateStage.none;
      }
    });
  });

  Future<void> _genuineCheck() =>
      _run(context.l10n.hwLedgerProgressGenuine, () async {
        final ok = await _hw.ledgerGenuineCheck();
        if (mounted) setState(() => _genuine = ok);
      });

  Future<void> _listApps() =>
      _run(context.l10n.hwLedgerProgressAllow, () async {
        final apps = await _hw.ledgerInstalledApps();
        if (mounted) setState(() => _installed = apps);
      });

  Future<void> _install(String app) async {
    if (_busy != null) return;
    if (!_connected && !await showLedgerConnectSheet(context, _hw.ledger)) {
      return;
    }
    if (!mounted) return;
    final ok = await showLedgerAppInstallDialog(context, _hw, app);
    if (!ok || !mounted) return;
    setState(() {
      _notice = context.l10n.hwLedgerInstalledApp(app);
      final installed = _installed;
      if (installed != null && !installed.any((a) => a.name == app)) {
        _installed = [
          ...installed,
          LedgerApp.fromJson({'name': app}),
        ];
      }
    });
  }

  Future<void> _remove(LedgerApp app) async {
    final l10n = context.l10n;
    final name = app.displayName ?? app.name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.hwLedgerRemoveTitle(name)),
        content: Text(l10n.hwLedgerRemoveBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.hwLedgerRemove),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(l10n.hwLedgerProgressRemoving(name), () async {
      await _hw.uninstallLedgerApp(app.name);
      if (!mounted) return;
      setState(() {
        _installed = _installed?.where((a) => a.name != app.name).toList();
        _notice = l10n.hwLedgerRemovedApp(name);
      });
    });
  }

  Future<void> _installOther() async {
    final l10n = context.l10n;
    if (_catalog == null) {
      await _run(l10n.hwLedgerReading, () async {
        final list = await _hw.ledgerCatalog();
        if (mounted) setState(() => _catalog = list);
      });
    }
    final catalog = _catalog;
    if (catalog == null || !mounted) return;
    final app = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CatalogSheet(apps: catalog),
    );
    if (app != null && mounted) await _install(app);
  }

  Future<void> _startUpdate() async {
    final l10n = context.l10n;
    final update = _status?.update;
    if (update == null) return;
    // The bootloader has no Bluetooth: an update that flashes the MCU needs a
    // cable.
    if (update.flashMcu && _hw.ledger.current?.kind == 'ble') {
      setState(() => _error = l10n.hwLedgerUpdateUsbOnly);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.hwLedgerUpdateConfirmTitle(update.version)),
        content: Text(l10n.hwLedgerUpdateConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.hwLedgerUpdateConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(l10n.hwLedgerProgressAllow, () async {
      final flashMcu = await _hw.startLedgerFirmwareUpdate(update);
      if (!mounted) return;
      setState(() {
        _update = update;
        _stage = flashMcu ? _UpdateStage.bootloader : _UpdateStage.restarting;
        _installed = null;
        _genuine = null;
      });
    });
  }

  Future<void> _continueUpdate() async {
    final l10n = context.l10n;
    await _run(l10n.hwLedgerProgressFirmware(0), () async {
      final st = await _hw.continueLedgerFirmware(update: _update);
      if (!mounted) return;
      final done = !st.bootloader && !st.updater;
      setState(() {
        _status = st;
        if (done) {
          _stage = _UpdateStage.none;
          _update = null;
          _notice = l10n.hwLedgerUpdateDone(st.firmware);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopScope(
      canPop: _busy == null,
      child: Scaffold(
        backgroundColor: TibaneColors.black,
        appBar: AppBar(title: Text(l10n.hwLedgerManageTitle)),
        body: SafeArea(
          child: ValueListenableBuilder<LedgerConnectionState>(
            valueListenable: _hw.ledger.state,
            builder: (context, conn, _) => ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                _connectionCard(conn),
                if (_busy != null) ...[
                  const SizedBox(height: 16),
                  _progressLine(),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: TibaneColors.orange),
                  ),
                ],
                if (_notice != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _notice!,
                    style: const TextStyle(color: TibaneColors.success),
                  ),
                ],
                const SizedBox(height: 16),
                _deviceCard(),
                const SizedBox(height: 16),
                _genuineCard(),
                const SizedBox(height: 16),
                _appsCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _progressLine() {
    final p = _progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          value: p?.type == 'progress' ? p?.progress : null,
        ),
        const SizedBox(height: 8),
        Text(
          p == null ? _busy! : ledgerProgressText(context, p),
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
      ],
    );
  }

  Widget _section(String title, List<Widget> children) => TibaneCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 10),
        ...children,
      ],
    ),
  );

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: TibaneColors.textMuted),
          ),
        ),
        Text(value),
      ],
    ),
  );

  Widget _muted(String text) => Text(
    text,
    style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
  );

  Widget _connectionCard(LedgerConnectionState conn) {
    final l10n = context.l10n;
    final device = conn.device;
    final connected = conn.isConnected && device != null;
    return TibaneCard(
      child: Row(
        children: [
          Icon(
            device?.kind == 'usb' ? Icons.usb : Icons.bluetooth,
            color: connected ? TibaneColors.success : TibaneColors.textDim,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              connected
                  ? l10n.hwLedgerConnectedTo(device.name)
                  : l10n.hwLedgerNotConnected,
            ),
          ),
          if (connected)
            TextButton(
              onPressed: _busy == null ? _hw.ledger.closeCurrent : null,
              child: Text(l10n.hwLedgerDisconnect),
            )
          else
            FilledButton(
              onPressed: _busy == null ? _connect : null,
              child: Text(l10n.hwLedgerConnect),
            ),
        ],
      ),
    );
  }

  Widget _deviceCard() {
    final l10n = context.l10n;
    final st = _status;
    final idle = _busy == null;
    return _section(l10n.hwLedgerDeviceSection, [
      if (st != null) ...[
        if (st.model != null) _row(l10n.hwLedgerModel, st.model!),
        _row(l10n.hwLedgerFirmware, st.firmware),
        const SizedBox(height: 8),
      ],
      switch (_stage) {
        _UpdateStage.restarting => _muted(l10n.hwLedgerUpdateRestarting),
        _UpdateStage.bootloader => _muted(l10n.hwLedgerUpdateBootloader),
        _UpdateStage.none when st?.updater ?? false => _muted(
          l10n.hwLedgerUpdateInProgress,
        ),
        _UpdateStage.none when st?.update != null => _muted(
          l10n.hwLedgerUpdateAvailable(st!.update!.version),
        ),
        _UpdateStage.none when st?.updateError != null => _muted(
          l10n.hwLedgerUpdateCheckFailed(st!.updateError!),
        ),
        _UpdateStage.none when st != null => _muted(l10n.hwLedgerUpToDate),
        _ => _muted(l10n.hwLedgerDeviceHint),
      },
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (_stage != _UpdateStage.none || (st?.updater ?? false))
            FilledButton(
              onPressed: idle ? _continueUpdate : null,
              child: Text(l10n.hwLedgerUpdateContinue),
            )
          else if (st?.update != null)
            FilledButton(
              onPressed: idle ? _startUpdate : null,
              child: Text(l10n.hwLedgerUpdateFirmware),
            ),
          OutlinedButton(
            onPressed: idle ? _checkDevice : null,
            child: Text(l10n.hwLedgerCheckDevice),
          ),
        ],
      ),
    ]);
  }

  Widget _genuineCard() {
    final l10n = context.l10n;
    final genuine = _genuine;
    return _section(l10n.hwLedgerGenuineCheck, [
      if (genuine == null)
        _muted(l10n.hwLedgerGenuineHint)
      else
        Row(
          children: [
            Icon(
              genuine ? Icons.verified : Icons.gpp_bad,
              color: genuine ? TibaneColors.success : TibaneColors.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                genuine ? l10n.hwLedgerGenuineOk : l10n.hwLedgerGenuineFail,
              ),
            ),
          ],
        ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: _busy == null ? _genuineCheck : null,
          child: Text(l10n.hwLedgerGenuineRun),
        ),
      ),
    ]);
  }

  Widget _appsCard() {
    final l10n = context.l10n;
    final installed = _installed;
    final idle = _busy == null;
    final names = installed?.map((a) => a.name).toSet();
    final others =
        installed?.where((a) => !_needed.contains(a.name)).toList() ?? const [];
    return _section(l10n.hwLedgerAppsSection, [
      _muted(l10n.hwLedgerAppsHint),
      const SizedBox(height: 8),
      for (final app in _needed)
        _appRow(
          app,
          names == null
              ? l10n.hwLedgerAppUnknown
              : names.contains(app)
              ? l10n.hwLedgerAppInstalled
              : l10n.hwLedgerAppNotInstalled,
          action: names?.contains(app) ?? false
              ? TextButton(
                  onPressed: idle
                      ? () =>
                            _remove(installed!.firstWhere((a) => a.name == app))
                      : null,
                  child: Text(l10n.hwLedgerRemove),
                )
              : TextButton(
                  onPressed: idle ? () => _install(app) : null,
                  child: Text(l10n.hwLedgerInstall),
                ),
        ),
      if (installed != null && others.isNotEmpty) const Divider(height: 24),
      for (final app in others)
        _appRow(
          app.displayName ?? app.name,
          app.version ?? '',
          action: TextButton(
            onPressed: idle ? () => _remove(app) : null,
            child: Text(l10n.hwLedgerRemove),
          ),
        ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: idle ? _listApps : null,
            child: Text(l10n.hwLedgerListApps),
          ),
          OutlinedButton(
            onPressed: idle ? _installOther : null,
            child: Text(l10n.hwLedgerInstallOther),
          ),
        ],
      ),
    ]);
  }

  Widget _appRow(String name, String state, {required Widget action}) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name),
            if (state.isNotEmpty)
              Text(
                state,
                style: const TextStyle(
                  color: TibaneColors.textMuted,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      action,
    ],
  );
}

/// Pick an app from the device's catalog.
class _CatalogSheet extends StatefulWidget {
  const _CatalogSheet({required this.apps});

  final List<LedgerApp> apps;

  @override
  State<_CatalogSheet> createState() => _CatalogSheetState();
}

class _CatalogSheetState extends State<_CatalogSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final q = _query.toLowerCase();
    final apps = widget.apps
        .where(
          (a) =>
              q.isEmpty ||
              a.name.toLowerCase().contains(q) ||
              (a.displayName?.toLowerCase().contains(q) ?? false),
        )
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 8 + context.keyboardInset),
        child: SizedBox(
          height: context.screenSize.height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.hwLedgerSearchApps,
                  prefixIcon: const Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: apps.length,
                  itemBuilder: (_, i) {
                    final a = apps[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(a.displayName ?? a.name),
                      subtitle: a.version == null ? null : Text(a.version!),
                      onTap: () => Navigator.of(context).pop(a.name),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
