import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Default start page when the user hasn't picked one. Kept here (not
/// in solana_constants.dart) because the in-app browser is a generic
/// webview, not Solana-specific — and because UkComplianceService
/// overrides this independently with a neutral search engine for UK
/// users.
const String kDefaultBrowserStartPage = 'https://www.tibane.net';

const String _kSeedFavoriteTitle = 'Tibane Labs';
const String _kSeedFavoriteUrl = 'https://www.tibane.net';

/// A user-saved entry in the in-app browser's favorites list.
@immutable
class BrowserFavorite {
  final String title;
  final String url;

  const BrowserFavorite({required this.title, required this.url});

  Map<String, dynamic> toJson() => {'title': title, 'url': url};

  factory BrowserFavorite.fromJson(Map<String, dynamic> json) =>
      BrowserFavorite(
        title: json['title'] as String? ?? '',
        url: json['url'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BrowserFavorite &&
          other.title == title &&
          other.url == url);

  @override
  int get hashCode => Object.hash(title, url);
}

/// Persistent browser preferences: the user's chosen start page and
/// favorites list, both stored in SharedPreferences. Notifies listeners
/// after every mutation so the browser chrome's star icon and the
/// favorites sheet stay in sync.
///
/// First-run seed: a single favorite "Tibane Labs" → tibane.net, so the
/// user has somewhere to land. Removable like any other favorite. The
/// seed only fires when the favorites list is missing entirely from
/// prefs — once the user has any list (including empty), we respect it.
class BrowserPreferences extends ChangeNotifier {
  static const _kStartPageKey = 'browser_start_page';
  static const _kFavoritesKey = 'browser_favorites_v1';

  String _startPage = kDefaultBrowserStartPage;
  List<BrowserFavorite> _favorites = const [];
  bool _ready = false;

  bool get isReady => _ready;

  /// Start page URL, falling back to [kDefaultBrowserStartPage] when
  /// the user hasn't overridden it.
  String get startPage => _startPage;

  /// Snapshot of the user's favorites in stored order.
  List<BrowserFavorite> get favorites => List.unmodifiable(_favorites);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kStartPageKey);
    if (stored != null && stored.trim().isNotEmpty) {
      _startPage = stored.trim();
    }
    final raw = prefs.getString(_kFavoritesKey);
    if (raw == null) {
      _favorites = const [
        BrowserFavorite(title: _kSeedFavoriteTitle, url: _kSeedFavoriteUrl),
      ];
      await _persistFavorites(prefs);
    } else {
      try {
        final list = (jsonDecode(raw) as List)
            .cast<Map<String, dynamic>>()
            .map(BrowserFavorite.fromJson)
            .where((f) => f.url.isNotEmpty)
            .toList(growable: false);
        _favorites = list;
      } catch (e) {
        debugPrint('BrowserPreferences: favorites parse failed: $e');
        _favorites = const [];
      }
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> setStartPage(String url) async {
    final trimmed = url.trim();
    final next = trimmed.isEmpty ? kDefaultBrowserStartPage : trimmed;
    if (next == _startPage) return;
    _startPage = next;
    final prefs = await SharedPreferences.getInstance();
    if (next == kDefaultBrowserStartPage) {
      await prefs.remove(_kStartPageKey);
    } else {
      await prefs.setString(_kStartPageKey, next);
    }
    notifyListeners();
  }

  /// True when [url] is already saved as a favorite, matching on the
  /// normalized URL (case-insensitive, trailing slash stripped) so the
  /// star toggles correctly across minor representation differences.
  bool isFavorite(String url) {
    final key = _normalize(url);
    if (key.isEmpty) return false;
    return _favorites.any((f) => _normalize(f.url) == key);
  }

  Future<void> addFavorite(BrowserFavorite fav) async {
    if (fav.url.trim().isEmpty) return;
    if (isFavorite(fav.url)) return;
    _favorites = [..._favorites, fav];
    final prefs = await SharedPreferences.getInstance();
    await _persistFavorites(prefs);
    notifyListeners();
  }

  Future<void> removeFavoriteByUrl(String url) async {
    final key = _normalize(url);
    if (key.isEmpty) return;
    final next =
        _favorites.where((f) => _normalize(f.url) != key).toList(growable: false);
    if (next.length == _favorites.length) return;
    _favorites = next;
    final prefs = await SharedPreferences.getInstance();
    await _persistFavorites(prefs);
    notifyListeners();
  }

  /// Convenience: flip a URL's favorite state in one call. Uses [title]
  /// when adding (falls back to the URL host).
  Future<void> toggleFavorite({required String url, required String title}) async {
    if (isFavorite(url)) {
      await removeFavoriteByUrl(url);
    } else {
      final t = title.trim().isEmpty ? _hostFromUrl(url) : title.trim();
      await addFavorite(BrowserFavorite(title: t, url: url));
    }
  }

  Future<void> _persistFavorites(SharedPreferences prefs) async {
    final json = jsonEncode(_favorites.map((f) => f.toJson()).toList());
    await prefs.setString(_kFavoritesKey, json);
  }

  static String _normalize(String url) {
    var s = url.trim().toLowerCase();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String _hostFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.host.isNotEmpty) return uri.host;
    } catch (_) {}
    return url;
  }
}
