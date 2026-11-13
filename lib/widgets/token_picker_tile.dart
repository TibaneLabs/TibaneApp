import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/tibane_theme.dart';
import 'tibane_card.dart';
import 'token_icon.dart';

class TokenPickerTile extends StatelessWidget {
  final String mint;
  final String name;
  final String? symbol;
  final String? imageUrl;
  final Widget? trailing;
  final bool framed;
  final VoidCallback onTap;

  const TokenPickerTile({
    super.key,
    required this.mint,
    required this.name,
    this.symbol,
    this.imageUrl,
    this.trailing,
    this.framed = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Row(
      children: [
        TokenIcon(
          imageUrl: imageUrl,
          mint: mint,
          symbol: symbol ?? '?',
          size: 43.2,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(
                  color: TibaneColors.text,
                  fontSize: 17.5,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (symbol != null)
                Text(
                  '\$$symbol',
                  style: GoogleFonts.dmSans(
                    textStyle: monoStyle(
                      fontSize: 12.65,
                      color: TibaneColors.textMuted,
                    ),
                    fontWeight: FontWeight.w500,
                  ).copyWith(fontFamilyFallback: cjkFallback),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
    if (framed) {
      return TibaneCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: content,
      );
    }
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: content,
      ),
    );
  }
}
