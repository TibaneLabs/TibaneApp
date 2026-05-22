import 'package:flutter/material.dart';

import '../theme/tibane_theme.dart';

/// Round token logo with a colored initial as fallback when [imageUrl] is
/// missing or fails to load.
class TokenIcon extends StatelessWidget {
  final String? imageUrl;
  final String symbol;
  final double size;

  const TokenIcon({
    super.key,
    this.imageUrl,
    required this.symbol,
    this.size = 32,
  });

  @override
  Widget build(BuildContext context) {
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size / 2),
        child: Image.network(
          imageUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, e, s) => _fallback(),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: TibaneColors.orange.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          symbol.isNotEmpty ? symbol[0].toUpperCase() : '?',
          style: TextStyle(
            color: TibaneColors.orange,
            fontWeight: FontWeight.w700,
            fontSize: size * 0.45,
          ),
        ),
      ),
    );
  }
}
