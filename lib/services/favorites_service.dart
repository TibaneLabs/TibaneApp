import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A favorited token with cached display metadata
class FavoriteToken {
  final String mint;
  final String? name;
  final String? symbol;
  final String? imageUrl;

  FavoriteToken({required this.mint, this.name, this.symbol, this.imageUrl});

  Map<String, dynamic> toJson() => {
    'mint': mint,
    'name': name,
    'symbol': symbol,
    'imageUrl': imageUrl,
  };

  factory FavoriteToken.fromJson(Map<String, dynamic> json) => FavoriteToken(
    mint: json['mint'] as String,
    name: json['name'] as String?,
    symbol: json['symbol'] as String?,
    imageUrl: json['imageUrl'] as String?,
  );
}

/// Manages favorite tokens, persisted via SharedPreferences
class FavoritesService extends ChangeNotifier {
  static const _key = 'favorite_tokens';
  List<FavoriteToken> _favorites = [];

  List<FavoriteToken> get favorites => List.unmodifiable(_favorites);

  bool isFavorite(String mint) => _favorites.any((f) => f.mint == mint);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _favorites = list
            .map((e) => FavoriteToken.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _favorites = [];
      }
    }
    // Seed default favorite on first run
    if (_favorites.isEmpty) {
      _favorites.add(
        FavoriteToken(
          mint: 'DRtvTCzfiKGhCVREmBbZdN9sB8PHeq9KdRZ3VmFhpump',
          name: 'Tibane Thecat',
          symbol: 'ChiefPussy',
        ),
      );
      await _save();
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_favorites.map((f) => f.toJson()).toList()),
    );
  }

  /// Toggle favorite. Provide metadata so it can be displayed without re-fetching.
  Future<void> toggle(
    String mint, {
    String? name,
    String? symbol,
    String? imageUrl,
  }) async {
    if (isFavorite(mint)) {
      _favorites.removeWhere((f) => f.mint == mint);
    } else {
      _favorites.add(
        FavoriteToken(
          mint: mint,
          name: name,
          symbol: symbol,
          imageUrl: imageUrl,
        ),
      );
    }
    notifyListeners();
    await _save();
  }

  /// Update cached metadata for a favorite (e.g. if name was unknown at toggle time)
  Future<void> updateMetadata(
    String mint, {
    String? name,
    String? symbol,
    String? imageUrl,
  }) async {
    final idx = _favorites.indexWhere((f) => f.mint == mint);
    if (idx < 0) return;
    _favorites[idx] = FavoriteToken(
      mint: mint,
      name: name ?? _favorites[idx].name,
      symbol: symbol ?? _favorites[idx].symbol,
      imageUrl: imageUrl ?? _favorites[idx].imageUrl,
    );
    notifyListeners();
    await _save();
  }
}
