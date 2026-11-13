import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/l10n.dart';
import '../../../services/hardware/hardware_wallet_service.dart';
import '../../../theme/tibane_theme.dart';
import 'airgap_scan_screen.dart';

/// Loop a multi-part QR payload (BC-UR fountain codes / BBQr) as an animated
/// code. A single part is shown still.
class AnimatedQr extends StatefulWidget {
  const AnimatedQr({super.key, required this.parts, this.size = 260});

  final List<String> parts;
  final double size;

  @override
  State<AnimatedQr> createState() => _AnimatedQrState();
}

class _AnimatedQrState extends State<AnimatedQr> {
  Timer? _timer;
  int _i = 0;

  @override
  void initState() {
    super.initState();
    if (widget.parts.length > 1) {
      _timer = Timer.periodic(const Duration(milliseconds: 280), (_) {
        if (mounted) setState(() => _i = (_i + 1) % widget.parts.length);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.parts.isEmpty) return SizedBox.square(dimension: widget.size);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: QrImageView(
        data: widget.parts[_i],
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.L,
        size: widget.size,
        gapless: true,
        backgroundColor: Colors.white,
      ),
    );
  }
}

/// The air-gapped half of a signing call: show libwallet's request as QR
/// codes, scan the signer's answer, and hand it back. Resolves true once the
/// answer was accepted, false when the person gave up (the caller then
/// cancels the request, which fails the waiting signing call).
Future<bool> showAirgapSignSheet(
  BuildContext context,
  AirgapSignPrompt prompt,
) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => _AirgapSignSheet(prompt: prompt),
  );
  return result ?? false;
}

class _AirgapSignSheet extends StatefulWidget {
  const _AirgapSignSheet({required this.prompt});

  final AirgapSignPrompt prompt;

  @override
  State<_AirgapSignSheet> createState() => _AirgapSignSheetState();
}

class _AirgapSignSheetState extends State<_AirgapSignSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _scan() async {
    final l10n = context.l10n;
    final decoderId = await scanAirgapPayload(
      context,
      client: widget.prompt.client,
      title: l10n.hwAirgapSignScan,
    );
    if (decoderId == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.prompt.submit(decoderId);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = l10n.hwAirgapSignWrong('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(
        widget.prompt.client.airgap.decoderDelete(decoderId).catchError((_) {}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_2, color: TibaneColors.text),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.hwAirgapSignTitle,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: LayoutBuilder(
                builder: (context, c) => AnimatedQr(
                  parts: widget.prompt.request.parts,
                  size: (c.maxWidth - 20).clamp(160, 300).toDouble(),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.hwAirgapSignBody,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: TibaneColors.orange),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _scan,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.qr_code_scanner),
              label: Text(l10n.hwAirgapSignScan),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              child: Text(l10n.actionCancel),
            ),
          ],
        ),
      ),
    );
  }
}
