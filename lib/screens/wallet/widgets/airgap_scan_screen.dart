import 'dart:async';

import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../l10n/l10n.dart';
import '../../../theme/tibane_theme.dart';

/// Scan an air-gapped signer's QR code — one frame, or an animated BC-UR /
/// BBQr sequence — into a libwallet decoder. Pops with the completed
/// decoder's id, or null when the person backs out (the decoder is then
/// deleted).
Future<String?> scanAirgapPayload(
  BuildContext context, {
  required LibwalletClient client,
  required String title,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _AirgapScanScreen(client: client, title: title),
  ),
);

class _AirgapScanScreen extends StatefulWidget {
  const _AirgapScanScreen({required this.client, required this.title});

  final LibwalletClient client;
  final String title;

  @override
  State<_AirgapScanScreen> createState() => _AirgapScanScreenState();
}

class _AirgapScanScreenState extends State<_AirgapScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
  );
  StreamSubscription<BarcodeCapture>? _sub;
  AirgapDecoder? _decoder;
  final Set<String> _seen = {};
  int _percent = 0;
  String? _error;
  bool _done = false;
  // Frames are fed one at a time so their order and the decoder's state stay
  // consistent; later frames wait in this chain.
  Future<void> _feeding = Future.value();

  @override
  void initState() {
    super.initState();
    _sub = _controller.barcodes.listen(_onCapture);
    unawaited(_startDecoder());
  }

  Future<void> _startDecoder() async {
    try {
      final d = await widget.client.airgap.newDecoder();
      if (!mounted) {
        unawaited(d.close());
        return;
      }
      _decoder = d;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _onCapture(BarcodeCapture capture) {
    for (final code in capture.barcodes) {
      final text = code.rawValue;
      if (text == null || text.isEmpty || !_seen.add(text)) continue;
      _feeding = _feeding.then((_) => _feed(text));
    }
  }

  Future<void> _feed(String frame) async {
    final decoder = _decoder;
    if (decoder == null || _done || !mounted) return;
    try {
      final p = await decoder.feed(frame);
      if (!mounted) return;
      setState(() {
        _percent = p.percent;
        _error = null;
      });
      if (p.complete) {
        _done = true;
        await _controller.stop();
        if (mounted) Navigator.of(context).pop(decoder.id);
      }
    } catch (e) {
      // A frame from another payload, or not a signer code at all: start
      // over so the person can rescan the right one.
      if (!mounted) return;
      setState(() => _error = e.toString());
      _seen.clear();
      final old = _decoder;
      _decoder = null;
      if (old != null) unawaited(old.close());
      await _startDecoder();
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_controller.dispose());
    final d = _decoder;
    if (d != null && !_done) unawaited(d.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller),
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
                if (_percent > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    child: Column(
                      children: [
                        LinearProgressIndicator(
                          value: _percent / 100,
                          color: TibaneColors.orange,
                          backgroundColor: Colors.white24,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.hwScanProgress(_percent),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                  child: Text(
                    _error ?? l10n.hwScanHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _error == null
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
      ),
    );
  }
}
