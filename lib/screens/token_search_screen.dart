import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/tibane_theme.dart';
import '../widgets/token_search.dart';
import 'token_detail_screen.dart';

class TokenSearchScreen extends StatelessWidget {
  const TokenSearchScreen({super.key});

  Future<void> _openToken(BuildContext context, String input) async {
    final mint = input.trim();
    if (mint.length < 32) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => TokenDetailScreen(mint: mint)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(context.l10n.tokensTitle)),
      body: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: TokenSearch(
          onResultSelected: (result) => _openToken(context, result.mint),
          onMintSubmitted: (mint) => _openToken(context, mint),
        ),
      ),
    );
  }
}
