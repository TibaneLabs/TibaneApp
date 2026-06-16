import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/browser_preferences.dart';
import '../../services/uk_compliance_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';

/// Sub-screen reached from Settings → "Browser". Lets the user override
/// the in-app browser's start page and remove favorites. The Browser
/// surface owns its own add-to-favorites flow (star icon in the URL
/// bar); this screen is for setting-shaped knobs.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final _startPageCtrl = TextEditingController();
  bool _initialised = false;

  @override
  void dispose() {
    _startPageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<BrowserPreferences>();
    final uk = context.watch<UkComplianceService>();
    if (!_initialised) {
      _startPageCtrl.text = prefs.startPage;
      _initialised = true;
    }

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Browser')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionLabel('Start page'),
              const SizedBox(height: 8),
              TibaneCard(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _startPageCtrl,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          hintText: kDefaultBrowserStartPage,
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (v) => prefs.setStartPage(v),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(
                            onPressed: () {
                              _startPageCtrl.text = kDefaultBrowserStartPage;
                              prefs.setStartPage(kDefaultBrowserStartPage);
                            },
                            child: const Text('Reset to default'),
                          ),
                          TextButton(
                            onPressed: () =>
                                prefs.setStartPage(_startPageCtrl.text),
                            child: const Text('Save'),
                          ),
                        ],
                      ),
                      if (uk.isUk)
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            'UK region: the browser ignores this setting and '
                            'opens a neutral search engine, per FCA compliance.',
                            style: TextStyle(
                              color: TibaneColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _SectionLabel('Favorites'),
              const SizedBox(height: 8),
              if (prefs.favorites.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Text(
                    'No favorites yet. Tap the star inside the URL bar to '
                    'add the current page.',
                    style: TextStyle(
                      color: TibaneColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                )
              else
                TibaneCard(
                  child: Column(
                    children: [
                      for (var i = 0; i < prefs.favorites.length; i++) ...[
                        if (i > 0)
                          const Divider(
                            color: TibaneColors.dark,
                            height: 1,
                          ),
                        _FavoriteRow(
                          favorite: prefs.favorites[i],
                          onRemove: () => prefs
                              .removeFavoriteByUrl(prefs.favorites[i].url),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FavoriteRow extends StatelessWidget {
  final BrowserFavorite favorite;
  final VoidCallback onRemove;

  const _FavoriteRow({required this.favorite, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.star, size: 18, color: TibaneColors.orange),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  favorite.title.isEmpty ? favorite.url : favorite.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  favorite.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TibaneColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onRemove,
            color: TibaneColors.textDim,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: TibaneColors.textMuted,
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
