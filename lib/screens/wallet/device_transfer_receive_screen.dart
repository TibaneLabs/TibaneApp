import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';

/// Pairing codes from libwallet's `exportToDevice` are opaque strings that
/// currently take this URL form. Treated only as a recognition prefix —
/// the rest is handed verbatim to `importFromDevice`.
const String _deviceTransferPrefix = 'tibane://device-transfer';

/// Legacy wallet-backup QR envelope. The app no longer scans these, but we
/// still recognise the prefix to give a clear "wrong QR" hint.
const String _backupQrPrefix = 'TIBW1:';

enum _Phase { scanning, importing, password, error, done }

/// New-device side of a device-to-device wallet transfer. Scans the QR
/// painted by the old device, drives `importFromDevice` (the wallet +
/// StoreKey device share arrive over libwallet's encrypted channel), then
/// asks for the wallet password to finish setup. No 2FA reshare — the device
/// share travels with the wallet.
///
/// Multi-wallet: the received wallet is ADDED to the list. The user chooses
/// whether to switch to it now or keep the current wallet active.
class DeviceTransferReceiveScreen extends StatefulWidget {
  const DeviceTransferReceiveScreen({super.key});

  @override
  State<DeviceTransferReceiveScreen> createState() =>
      _DeviceTransferReceiveScreenState();
}

class _DeviceTransferReceiveScreenState
    extends State<DeviceTransferReceiveScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
  );
  final _pwCtrl = TextEditingController();

  StreamSubscription<BarcodeCapture>? _sub;
  WalletService? _wallet;
  _Phase _phase = _Phase.scanning;
  String? _message; // error / hint text
  String? _scanHint; // transient hint shown while still scanning
  bool _busy = false;
  bool _handling = false; // a scanned code is being processed

  @override
  void initState() {
    super.initState();
    _sub = _controller.barcodes.listen(_onCapture);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Cache the service so the PopScope cleanup can run during disposal,
    // when reading from `context` would be unsafe.
    _wallet = context.read<WalletService>();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_controller.dispose());
    _pwCtrl.dispose();
    super.dispose();
  }

  void _onCapture(BarcodeCapture capture) {
    if (_phase != _Phase.scanning || _handling) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null || raw.isEmpty) continue;
      if (raw.startsWith(_deviceTransferPrefix)) {
        _handling = true;
        unawaited(_startImport(raw));
        return;
      }
      if (raw.startsWith(_backupQrPrefix)) {
        setState(() => _scanHint =
            context.l10n.deviceReceiveWrongQr);
        return;
      }
      setState(() => _scanHint =
          context.l10n.deviceReceiveNotTransferCode);
      return;
    }
  }

  Future<void> _startImport(String code) async {
    final wallet = _wallet ?? context.read<WalletService>();
    await _controller.stop();
    if (!mounted) return;

    // Multi-wallet: a received wallet is added to the list, not swapped in.
    // No disconnect — the current wallet stays active and untouched.
    setState(() {
      _phase = _Phase.importing;
      _message = null;
      _scanHint = null;
    });

    final ok = await wallet.libwallet.importViaDeviceTransfer(code);
    if (!mounted) return;
    _handling = false;
    if (ok) {
      setState(() => _phase = _Phase.password);
    } else {
      logError('[DeviceTransferReceive._startImport] transfer failed: ${wallet.libwallet.error}');
      setState(() {
        _phase = _Phase.error;
        _message = WalletError.from(
          wallet.libwallet.error ?? 'Transfer failed',
        ).message;
      });
    }
  }

  /// Finish setup. [makeActive] true → switch to the received wallet now;
  /// false → add it to the list and keep the current wallet active.
  Future<void> _activate({required bool makeActive}) async {
    if (_busy) return;
    final pw = _pwCtrl.text;
    if (pw.isEmpty) {
      setState(() => _message = context.l10n.deviceReceiveEnterPassword);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final wallet = context.read<WalletService>();
    final ok = await wallet.libwallet.activateAfterTransfer(
      pw,
      makeActive: makeActive,
    );
    if (!mounted) return;
    if (ok) {
      _phase = _Phase.done;
      // Only switch the app to the received wallet when the user chose to use
      // it now; otherwise leave the current active wallet in place.
      if (makeActive) await wallet.useLibwallet();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } else {
      logError('[DeviceTransferReceive._activate] activate failed: ${wallet.libwallet.error}');
      setState(() {
        _busy = false;
        _message = WalletError.from(
          wallet.libwallet.error ?? 'Could not activate wallet',
        ).message;
      });
    }
  }

  Future<void> _rescan() async {
    _handling = false;
    setState(() {
      _phase = _Phase.scanning;
      _message = null;
      _scanHint = null;
    });
    try {
      await _controller.start();
    } catch (_) {
      /* MobileScanner rebuild restarts it; ignore double-start races. */
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // A transfer that imported but was never activated (user left at the
      // password step, or cancelled mid-wait) gets rolled back so it doesn't
      // strand a half-set-up wallet. The active wallet is never touched.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _phase != _Phase.done) {
          unawaited(_wallet?.libwallet.abandonPendingTransfer());
        }
      },
      child: _buildScaffold(),
    );
  }

  Widget _buildScaffold() {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        backgroundColor:
            _phase == _Phase.scanning ? Colors.black : TibaneColors.black,
        foregroundColor: Colors.white,
        title: Text(l10n.deviceReceiveTitle),
        actions: _phase == _Phase.scanning
            ? [
                IconButton(
                  tooltip: l10n.deviceReceiveSwitchCamera,
                  onPressed: () => _controller.switchCamera(),
                  icon: const Icon(Icons.cameraswitch),
                ),
                _TorchButton(controller: _controller),
              ]
            : null,
      ),
      body: switch (_phase) {
        _Phase.scanning => _buildScanner(),
        _Phase.importing => _buildWaiting(),
        _Phase.password => _buildPassword(),
        _Phase.error => _buildError(),
        _Phase.done => const SizedBox.shrink(),
      },
    );
  }

  Widget _buildScanner() {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controller,
          errorBuilder: (context, error) => _ScannerErrorView(error: error),
        ),
        SafeArea(
          child: Column(
            children: [
              const Spacer(),
              Center(
                child: Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    border: Border.all(color: TibaneColors.orange, width: 3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _scanHint ?? context.l10n.deviceReceiveScanHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _scanHint == null
                        ? Colors.white.withValues(alpha: 0.85)
                        : TibaneColors.orange,
                    height: 1.4,
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWaiting() {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: TibaneColors.orange),
          const SizedBox(height: 24),
          Text(
            l10n.deviceReceiveWaiting,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: TibaneColors.text,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.deviceReceiveWaitingHint,
            textAlign: TextAlign.center,
            style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
          ),
          const SizedBox(height: 32),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              l10n.actionCancel,
              style: const TextStyle(color: TibaneColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPassword() {
    final l10n = context.l10n;
    // Whether there's already an active wallet to keep — drives the
    // "use now" vs "just add" choice. When there's none, the received wallet
    // becomes active unconditionally.
    final hasActive = (_wallet ?? context.read<WalletService>())
        .libwallet
        .hasWallet;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(
              Icons.check_circle_outline,
              color: TibaneColors.orange,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.deviceReceivePasswordTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: TibaneColors.text,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.deviceReceivePasswordHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _pwCtrl,
              obscureText: true,
              enabled: !_busy,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) =>
                  _busy ? null : _activate(makeActive: !hasActive),
              decoration: InputDecoration(labelText: l10n.labelPassword),
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(
                _message!,
                style: const TextStyle(color: TibaneColors.error),
              ),
            ],
            const SizedBox(height: 24),
            if (hasActive) ...[
              // There's already an active wallet — let the user pick.
              FilledButton(
                onPressed: _busy ? null : () => _activate(makeActive: true),
                style: FilledButton.styleFrom(
                  backgroundColor: TibaneColors.orange,
                  foregroundColor: TibaneColors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  _busy ? l10n.deviceReceiveSettingUp : l10n.deviceReceiveAddAndSwitch,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: _busy ? null : () => _activate(makeActive: false),
                style: OutlinedButton.styleFrom(
                  foregroundColor: TibaneColors.text,
                  side: const BorderSide(color: TibaneColors.textDim),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  l10n.deviceReceiveAddKeepCurrent,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ] else
              // First/only wallet — just finish setup; it becomes active.
              FilledButton(
                onPressed: _busy ? null : () => _activate(makeActive: true),
                style: FilledButton.styleFrom(
                  backgroundColor: TibaneColors.orange,
                  foregroundColor: TibaneColors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  _busy ? l10n.deviceReceiveSettingUp : l10n.deviceReceiveFinishSetup,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    final l10n = context.l10n;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(
              Icons.error_outline,
              color: TibaneColors.error,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              _message ?? l10n.transferFailed,
              textAlign: TextAlign.center,
              style: const TextStyle(color: TibaneColors.text, height: 1.4),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: _rescan,
              style: FilledButton.styleFrom(
                backgroundColor: TibaneColors.orange,
                foregroundColor: TibaneColors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(
                l10n.deviceReceiveScanAgain,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                l10n.actionCancel,
                style: const TextStyle(color: TibaneColors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TorchButton extends StatelessWidget {
  final MobileScannerController controller;

  const _TorchButton({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, state, _) {
        if (!state.isInitialized || !state.isRunning) {
          return const SizedBox.shrink();
        }
        final icon = switch (state.torchState) {
          TorchState.auto => Icons.flash_auto,
          TorchState.on => Icons.flash_on,
          TorchState.off => Icons.flash_off,
          TorchState.unavailable => Icons.no_flash,
        };
        return IconButton(
          tooltip: context.l10n.deviceReceiveToggleTorch,
          onPressed: state.torchState == TorchState.unavailable
              ? null
              : controller.toggleTorch,
          icon: Icon(icon),
        );
      },
    );
  }
}

class _ScannerErrorView extends StatelessWidget {
  final MobileScannerException error;

  const _ScannerErrorView({required this.error});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final code = error.errorCode;
    final body = switch (code) {
      MobileScannerErrorCode.permissionDenied =>
        l10n.deviceReceiveCameraPermission,
      MobileScannerErrorCode.unsupported =>
        l10n.deviceReceiveCameraUnsupported,
      _ => l10n.deviceReceiveCameraError(
          error.errorDetails?.message ?? code.message),
    };
    return ColoredBox(
      color: Colors.black,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, height: 1.4),
          ),
        ),
      ),
    );
  }
}
