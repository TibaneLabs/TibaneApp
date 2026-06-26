import 'dart:async';

import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/wallet/libwallet_backend.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import 'inapp_unlock_screen.dart';
import 'widgets/authorize_and_sign.dart';

enum _Phase { starting, showing, expired, confirming, done, declined, error }

/// Old-device side of a device-to-device wallet transfer. Opens a session
/// via `exportToDevice`, paints the opaque pairing code as a QR, and waits
/// for the new device to connect. On the `wallet:transfer:pair_received`
/// event it prompts the user, then releases this device's StoreKey share
/// via `exportToDeviceConfirm` so the new device gets a fully signable
/// wallet (no reshare).
///
/// Multi-wallet: any wallet can be transferred from its detail screen — if
/// it isn't the active/unlocked wallet, the screen switches to and unlocks
/// it first (only the active wallet's StoreKey share is in memory to release).
class DeviceTransferSendScreen extends StatefulWidget {
  /// The wallet to transfer (from its detail screen).
  final String walletId;

  /// Display name, used to make the prepare prompt say which wallet.
  final String? walletName;

  const DeviceTransferSendScreen({
    super.key,
    required this.walletId,
    this.walletName,
  });

  @override
  State<DeviceTransferSendScreen> createState() =>
      _DeviceTransferSendScreenState();
}

class _DeviceTransferSendScreenState extends State<DeviceTransferSendScreen> {
  WalletService? _wallet;
  StreamSubscription<LibwalletEvent>? _eventSub;
  Timer? _ticker;
  DeviceTransferSession? _session;
  _Phase _phase = _Phase.starting;
  String? _message;
  Duration _remaining = Duration.zero;
  bool _pairHandled = false;

  /// Lockless: the StoreKey share read on-demand at start, released at confirm.
  /// Null on the legacy path (which uses the cached session).
  String? _exportPriv;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _wallet = context.read<WalletService>();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_eventSub?.cancel());
    final s = _session;
    // Best-effort cancel if the session was open and didn't complete.
    if (s != null && _phase != _Phase.done) {
      unawaited(_wallet?.libwallet.cancelDeviceTransferExport(s.sid));
    }
    super.dispose();
  }

  Future<void> _start() async {
    final wallet = _wallet ?? context.read<WalletService>();
    final backend = wallet.libwallet;
    if (useSignSheet(wallet)) {
      // Lockless: switch to the target (free), confirm intent, then read its
      // StoreKey share on-demand (biometric). Releasing the device share is a
      // deliberate export action, so authenticate here rather than at every tx.
      final proceed = await _confirmPrepareDialog(
        DeviceTransferSendRoute.unlockFirst,
      );
      if (!mounted) return;
      if (!proceed) {
        Navigator.of(context).pop(false);
        return;
      }
      if (backend.walletId != widget.walletId) {
        final r = await backend.switchWallet(widget.walletId);
        if (!mounted) return;
        if (r != SwitchResult.ok) {
          debugPrint('[device-transfer] switch to ${widget.walletId} failed: '
              '$r (${backend.error})');
          setState(() {
            _phase = _Phase.error;
            _message = 'Could not open the wallet to transfer it.';
          });
          return;
        }
      }
      _exportPriv = await backend.readActiveStoreKeyPrivate();
      if (!mounted) return;
      if (_exportPriv == null) {
        debugPrint('[device-transfer] StoreKey unreadable for '
            '${widget.walletId} — needs 2FA recovery');
        setState(() {
          _phase = _Phase.error;
          _message = "Could not read this wallet's device key. Recover it via "
              '2FA, then try again.';
        });
        return;
      }
    } else {
      // Legacy: releasing the StoreKey share needs the target wallet active +
      // unlocked. ensureUnlocked switches and/or unlocks it first.
      final route = LibwalletBackend.deviceTransferSendRoute(
        activeWalletId: backend.walletId,
        targetWalletId: widget.walletId,
        isUnlocked: backend.isUnlocked,
      );
      if (route != DeviceTransferSendRoute.exportDirectly) {
        final proceed = await _confirmPrepareDialog(route);
        if (!mounted) return;
        if (!proceed) {
          Navigator.of(context).pop(false);
          return;
        }
        final ready = await InAppUnlockScreen.ensureUnlocked(
          context,
          walletId: widget.walletId,
        );
        if (!mounted) return;
        if (!ready) {
          Navigator.of(context).pop(false);
          return;
        }
      }
    }
    try {
      final client = await backend.ensureClient();
      if (!mounted) return;
      // Subscribe BEFORE opening the session so we can't miss pair_received.
      _eventSub = client.events.listen(_onEvent);
      final session = await backend.startDeviceTransferExport(
        widget.walletId,
        storeKeyPriv: _exportPriv,
      );
      if (!mounted) return;
      setState(() {
        _session = session;
        _phase = _Phase.showing;
        _remaining = session.expiresAt.difference(DateTime.now());
      });
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } catch (e) {
      debugPrint('[device-transfer] source start/export failed: $e');
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        // Map known codes (e.g. local_offline) to friendly copy.
        _message = LibwalletBackend.friendlyTransferError(e);
      });
    }
  }

  void _tick() {
    final s = _session;
    if (s == null) return;
    final left = s.expiresAt.difference(DateTime.now());
    if (left.inSeconds <= 0) {
      _ticker?.cancel();
      if (mounted && _phase == _Phase.showing) {
        setState(() {
          _phase = _Phase.expired;
          _remaining = Duration.zero;
        });
      }
      return;
    }
    if (mounted) setState(() => _remaining = left);
  }

  void _onEvent(LibwalletEvent e) {
    final s = _session;
    if (s == null || _pairHandled) return;
    if (e.event == 'wallet:transfer:pair_received' && e.data['sid'] == s.sid) {
      _pairHandled = true;
      unawaited(_onPairReceived(e.data));
    }
  }

  Future<void> _onPairReceived(Map<String, dynamic> data) async {
    final fingerprint = data['peer_fingerprint'] as String?;
    final approved = await _confirmSendDialog(fingerprint);
    if (!mounted) return;
    final s = _session;
    if (s == null) return;
    if (!approved) {
      setState(() => _phase = _Phase.declined);
      await _wallet?.libwallet.cancelDeviceTransferExport(s.sid);
      return;
    }
    setState(() => _phase = _Phase.confirming);
    try {
      await _wallet!.libwallet.confirmDeviceTransferExport(
        s.sid,
        storeKeyPriv: _exportPriv,
      );
      if (!mounted) return;
      _ticker?.cancel();
      setState(() => _phase = _Phase.done);
    } catch (e) {
      debugPrint('[device-transfer] source confirmDeviceTransferExport failed: $e');
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _message = 'Transfer confirmation failed: $e';
      });
    }
  }

  /// Yes/No prompt to switch to and/or unlock the wallet before transferring.
  Future<bool> _confirmPrepareDialog(DeviceTransferSendRoute route) async {
    final name = (widget.walletName != null && widget.walletName!.isNotEmpty)
        ? '“${widget.walletName}”'
        : 'this wallet';
    final body = route == DeviceTransferSendRoute.switchFirst
        ? 'To transfer $name to another device, it needs to be the active '
            'wallet and unlocked. Switch to it and unlock it now?'
        : 'To transfer $name to another device, it needs to be unlocked '
            'first. Unlock it now?';
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text(
          route == DeviceTransferSendRoute.switchFirst
              ? 'Switch & unlock wallet?'
              : 'Unlock wallet?',
        ),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'No',
              style: TextStyle(color: TibaneColors.textMuted),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: TibaneColors.orange,
              foregroundColor: TibaneColors.black,
            ),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<bool> _confirmSendDialog(String? fingerprint) async {
    final hasFp = fingerprint != null && fingerprint.isNotEmpty;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: const Text('Send wallet to new device?'),
        content: Text(
          'A device just connected to this transfer.'
          '${hasFp ? '\n\nDevice code: $fingerprint' : ''}\n\n'
          'Only approve if this is your own new device. It will receive a '
          'full copy of this wallet, including its device key.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: TibaneColors.textMuted),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: TibaneColors.orange,
              foregroundColor: TibaneColors.black,
            ),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _restart() async {
    _ticker?.cancel();
    unawaited(_eventSub?.cancel());
    _eventSub = null;
    _session = null;
    _pairHandled = false;
    setState(() {
      _phase = _Phase.starting;
      _message = null;
    });
    await _start();
  }

  String get _countdownText {
    final m = _remaining.inMinutes;
    final s = _remaining.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Transfer to new device')),
      body: SafeArea(
        child: switch (_phase) {
          _Phase.starting => _centered(
            const CircularProgressIndicator(color: TibaneColors.orange),
            'Preparing transfer…',
          ),
          _Phase.showing => _buildShowing(),
          _Phase.expired => _buildSimple(
            Icons.timer_off_outlined,
            'This transfer code expired.',
            showRetry: true,
          ),
          _Phase.confirming => _centered(
            const CircularProgressIndicator(color: TibaneColors.orange),
            'Sending wallet to the new device…',
          ),
          _Phase.done => _buildDone(),
          _Phase.declined => _buildSimple(
            Icons.cancel_outlined,
            'Transfer cancelled.',
            showRetry: true,
          ),
          _Phase.error => _buildSimple(
            Icons.error_outline,
            _message ?? 'Transfer failed',
            showRetry: true,
          ),
        },
      ),
    );
  }

  Widget _buildShowing() {
    final code = _session?.pairingCode ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'On your new device, open Wallets & Accounts → "Receive wallet '
            'from another device", then scan this code.',
            textAlign: TextAlign.center,
            style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
          ),
          const SizedBox(height: 20),
          Center(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: code,
                version: QrVersions.auto,
                size: 280,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Expires in $_countdownText',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: TibaneColors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Keep this screen open. You’ll be asked to approve once the other '
            'device connects.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: TibaneColors.textDim,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDone() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.check_circle_outline,
            color: TibaneColors.orange,
            size: 56,
          ),
          const SizedBox(height: 16),
          const Text(
            'Wallet sent',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: TibaneColors.text,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Your new device received the wallet. Enter the wallet password '
            'on that device to finish setting it up.',
            textAlign: TextAlign.center,
            style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: TibaneColors.orange,
              foregroundColor: TibaneColors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text(
              'Done',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimple(IconData icon, String message, {bool showRetry = false}) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(icon, color: TibaneColors.orange, size: 48),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: TibaneColors.text, height: 1.4),
          ),
          const SizedBox(height: 28),
          if (showRetry)
            FilledButton(
              onPressed: _restart,
              style: FilledButton.styleFrom(
                backgroundColor: TibaneColors.orange,
                foregroundColor: TibaneColors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text(
                'Generate new code',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Close',
              style: TextStyle(color: TibaneColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _centered(Widget indicator, String text) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          indicator,
          const SizedBox(height: 24),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: TibaneColors.text,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
