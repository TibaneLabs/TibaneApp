import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/gradient_button.dart';
import 'inapp_export_screen.dart';

const String _backupIllustrationAsset = 'assets/backupimg.png';
const double _backupIllustrationAspectRatio = 960 / 639;
const Color _backupScreenBackground = Color(0xFF06050A);

class PostCreateBackupScreen extends StatelessWidget {
  const PostCreateBackupScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  Future<void> _openManualBackup(BuildContext context) async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const InAppExportScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onDone();
      },
      child: Scaffold(
        backgroundColor: _backupScreenBackground,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compactHeight = constraints.maxHeight < 720;
              final horizontalPadding = constraints.maxWidth < 360
                  ? 24.0
                  : 32.0;
              final padding = EdgeInsets.fromLTRB(
                horizontalPadding,
                compactHeight ? 14 : 24,
                horizontalPadding,
                compactHeight ? 18 : 28,
              );
              final contentWidth = math.max(
                0.0,
                constraints.maxWidth - padding.horizontal,
              );
              return SingleChildScrollView(
                padding: padding,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - padding.vertical).clamp(
                      0.0,
                      double.infinity,
                    ),
                  ),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(height: compactHeight ? 4 : 12),
                        _BackupIllustrationSlot(
                          maxWidth: contentWidth,
                          compactHeight: compactHeight,
                        ),
                        SizedBox(height: compactHeight ? 22 : 30),
                        Text(
                          l10n.postCreateBackupTitle,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                color: TibaneColors.text,
                                fontSize: compactHeight ? 32 : 36,
                                height: 1.08,
                                letterSpacing: 0,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        SizedBox(height: compactHeight ? 20 : 28),
                        Text(
                          l10n.postCreateBackupBody,
                          style: TextStyle(
                            color: TibaneColors.textMuted,
                            fontSize: compactHeight ? 17.5 : 19,
                            height: compactHeight ? 1.55 : 1.68,
                            letterSpacing: 0,
                          ),
                        ),
                        const Spacer(),
                        SizedBox(height: compactHeight ? 24 : 36),
                        GradientButton(
                          label: l10n.postCreateBackupButton,
                          expanded: true,
                          onPressed: () {
                            _openManualBackup(context);
                          },
                        ),
                        SizedBox(height: compactHeight ? 12 : 20),
                        TextButton(
                          onPressed: onDone,
                          child: Text(
                            l10n.postCreateBackupSkip,
                            style: const TextStyle(
                              color: TibaneColors.textMuted,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _BackupIllustrationSlot extends StatelessWidget {
  const _BackupIllustrationSlot({
    required this.maxWidth,
    required this.compactHeight,
  });

  final double maxWidth;
  final bool compactHeight;

  @override
  Widget build(BuildContext context) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final maxImageWidth = compactHeight ? 310.0 : 380.0;
    final imageWidth = maxWidth.clamp(0.0, maxImageWidth).toDouble();
    final naturalHeight = imageWidth / _backupIllustrationAspectRatio;
    final maxImageHeight = (viewportHeight * (compactHeight ? 0.29 : 0.31))
        .clamp(190.0, compactHeight ? 220.0 : 280.0)
        .toDouble();
    final imageHeight = math.min(naturalHeight, maxImageHeight);

    return Center(
      child: SizedBox(
        width: imageWidth,
        height: imageHeight,
        child: Image.asset(_backupIllustrationAsset, fit: BoxFit.contain),
      ),
    );
  }
}
