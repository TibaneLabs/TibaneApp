import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Disposable display data only. Ownership is inferred from successful local
/// balance snapshots; no account addresses, amounts or source URLs are stored.
class TokenIconCache {
  TokenIconCache({
    Future<Directory> Function()? directory,
    Future<Uint8List?> Function(Uri)? fetchThumbnail,
    DateTime Function()? now,
    this.maxBytes = 10 * 1024 * 1024,
  }) : _directory = directory ?? _cacheDirectory,
       _fetchThumbnail = fetchThumbnail ?? _downloadThumbnail,
       _now = now ?? DateTime.now;

  static const retention = Duration(days: 3);
  static final _solanaMint = RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,44}$');
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  final Future<Directory> Function() _directory;
  final Future<Uint8List?> Function(Uri) _fetchThumbnail;
  final DateTime Function() _now;
  final int maxBytes;
  final _entries = <String, _CachedIcon>{};
  final _holdingsByOwner = <String, Set<String>>{};
  final _downloads = <(String, String), Future<Uint8List?>>{};
  Future<void> _queue = Future.value();
  late final Future<Directory?> _ready = _open();

  static bool canIdentifySolanaMint(String? mint) =>
      mint != null && _solanaMint.hasMatch(mint);

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static String _mintKey(String mint) => _hash('solana:$mint');

  static Future<Directory> _cacheDirectory() async {
    final root = await getApplicationCacheDirectory();
    return Directory('${root.path}/token-icons-v1');
  }

  Future<T> _serialize<T>(Future<T> Function(Directory? dir) run) {
    final next = _queue.then((_) async => run(await _ready));
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<Directory?> _open() async {
    try {
      final dir = await _directory();
      await dir.create(recursive: true);
      final index = File('${dir.path}/index.json');
      if (await index.exists()) {
        try {
          final rows = jsonDecode(await index.readAsString()) as Map;
          for (final MapEntry(:key, :value) in rows.entries) {
            if (key is! String || !_digest.hasMatch(key) || value is! Map) {
              continue;
            }
            final stat = await _image(dir, key).stat();
            if (stat.type != FileSystemEntityType.file) continue;
            _entries[key] = _CachedIcon(
              source: value['source'] as String? ?? '',
              owners: (value['owners'] as List? ?? [])
                  .whereType<String>()
                  .toSet(),
              releasedAt: DateTime.tryParse('${value['releasedAt'] ?? ''}'),
              lastUsed: stat.modified,
              bytes: stat.size,
            );
          }
        } on FormatException {
          _entries.clear();
        } on TypeError {
          _entries.clear();
        }
      }
      await for (final file in dir.list(followLinks: false)) {
        final name = file.uri.pathSegments.last;
        if (file is File &&
            (name.endsWith('.tmp') ||
                (name.endsWith('.png') &&
                    !_entries.containsKey(name.split('.').first)))) {
          await file.delete();
        }
      }
      if (await _trim(dir)) await _save(dir);
      return dir;
    } on Object {
      // A purged or unavailable cache must not prevent token icons from loading.
      _entries.clear();
      return null;
    }
  }

  File _image(Directory dir, String key) => File('${dir.path}/$key.png');

  Future<void> _save(Directory dir) async {
    final temp = File('${dir.path}/index.tmp');
    await temp.writeAsString(
      jsonEncode({
        for (final entry in _entries.entries)
          entry.key: {
            'source': entry.value.source,
            'owners': entry.value.owners.toList(),
            'releasedAt': entry.value.releasedAt?.toUtc().toIso8601String(),
          },
      }),
    );
    await temp.rename('${dir.path}/index.json');
  }

  bool _expired(_CachedIcon entry, DateTime now) =>
      entry.owners.isEmpty &&
      !now.isBefore((entry.releasedAt ?? entry.lastUsed).add(retention));

  Future<void> _remove(Directory dir, String key) async {
    final file = _image(dir, key);
    if (await file.exists()) await file.delete();
    _entries.remove(key);
  }

  Future<bool> _trim(Directory dir) async {
    final now = _now();
    var changed = false;
    for (final key in _entries.keys.toList()) {
      if (_expired(_entries[key]!, now)) {
        await _remove(dir, key);
        changed = true;
      }
    }
    var size = _entries.values.fold(0, (sum, entry) => sum + entry.bytes);
    if (size <= maxBytes) return changed;
    final oldest = _entries.entries.toList()
      ..sort((a, b) {
        final priority = (a.value.owners.isEmpty ? 0 : 1).compareTo(
          b.value.owners.isEmpty ? 0 : 1,
        );
        return priority != 0
            ? priority
            : a.value.lastUsed.compareTo(b.value.lastUsed);
      });
    for (final entry in oldest) {
      await _remove(dir, entry.key);
      size -= entry.value.bytes;
      if (size <= maxBytes) break;
    }
    return true;
  }

  /// Record only a complete, successful on-chain snapshot for this owner.
  Future<void> recordSolanaHoldings(
    String owner,
    Iterable<String> mints,
  ) async {
    final ownerKey = _hash('owner:solana:$owner');
    final held = mints.where(canIdentifySolanaMint).map(_mintKey).toSet();
    try {
      await _serialize((dir) async {
        _holdingsByOwner[ownerKey] = held;
        if (dir == null) return;
        var changed = false;
        for (final MapEntry(:key, value: entry) in _entries.entries) {
          if (held.contains(key)) {
            if (entry.owners.add(ownerKey)) changed = true;
            entry.releasedAt = null;
          } else if (entry.owners.remove(ownerKey)) {
            if (entry.owners.isEmpty) entry.releasedAt = _now();
            changed = true;
          }
        }
        if (await _trim(dir) || changed) await _save(dir);
      });
    } on Object {
      // The cache is independent of balances and can be rebuilt.
    }
  }

  /// Read a cached thumbnail, or fetch the first usable URL. A mint lookup
  /// without URLs never makes a network request.
  Future<Uint8List?> load({String? mint, List<String> urls = const []}) async {
    final source = urls.isEmpty ? '' : _hash(urls.first);
    if (source.isEmpty && !canIdentifySolanaMint(mint)) return null;
    final key = canIdentifySolanaMint(mint) ? _mintKey(mint!) : source;
    try {
      final cached = await _serialize((dir) async {
        if (dir == null) return null;
        final entry = _entries[key];
        if (entry == null) return null;
        if (_expired(entry, _now())) {
          await _remove(dir, key);
          await _save(dir);
          return null;
        }
        if (source.isNotEmpty && source != entry.source) return null;
        final file = _image(dir, key);
        if (!await file.exists()) return null;
        final bytes = await file.readAsBytes();
        entry.lastUsed = _now();
        await file.setLastModified(entry.lastUsed);
        return bytes;
      });
      if (cached != null || urls.isEmpty) return cached;
    } on Object {
      // A failed disk read can still be served from the image source below.
    }
    if (urls.isEmpty) return null;
    final pendingKey = (key, source);
    return _downloads.putIfAbsent(
      pendingKey,
      () => Future.microtask(() async {
        try {
          for (final url in urls) {
            final uri = Uri.tryParse(url);
            if (uri == null ||
                !const {'http', 'https'}.contains(uri.scheme) ||
                uri.host.isEmpty) {
              continue;
            }
            Uint8List? bytes;
            try {
              bytes = await _fetchThumbnail(uri);
            } on Object {
              continue;
            }
            if (bytes == null || bytes.isEmpty) continue;
            // A non-null local: [bytes] cannot be promoted inside the closure.
            final data = bytes;
            try {
              if (data.length <= maxBytes) {
                await _serialize((dir) async {
                  if (dir == null) return;
                  final previous = _entries[key];
                  final owners = <String>{
                    ...?previous?.owners,
                    for (final entry in _holdingsByOwner.entries)
                      if (entry.value.contains(key)) entry.key,
                  };
                  final file = _image(dir, key);
                  final temp = await File(
                    '${file.path}.tmp',
                  ).writeAsBytes(data);
                  await temp.rename(file.path);
                  final now = _now();
                  await file.setLastModified(now);
                  _entries[key] = _CachedIcon(
                    source: source,
                    owners: owners,
                    releasedAt: owners.isEmpty ? previous?.releasedAt : null,
                    lastUsed: now,
                    bytes: data.length,
                  );
                  await _trim(dir);
                  await _save(dir);
                });
              }
            } on Object {
              // Still display the freshly loaded image if storage fails.
            }
            return bytes;
          }
          return null;
        } finally {
          _downloads.remove(pendingKey);
        }
      }),
    );
  }

  static Future<Uint8List?> _downloadThumbnail(Uri uri) async {
    const downloadLimit = 2 * 1024 * 1024;
    final client = http.Client();
    try {
      final data = await (() async {
        final response = await client.send(http.Request('GET', uri));
        if (response.statusCode != 200 ||
            (response.contentLength ?? 0) > downloadLimit) {
          return null;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > downloadLimit) return null;
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      })().timeout(const Duration(seconds: 8));
      if (data == null || data.isEmpty) return null;
      final buffer = await ui.ImmutableBuffer.fromUint8List(data);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          if (descriptor.width > 4096 || descriptor.height > 4096) return null;
          final landscape = descriptor.width >= descriptor.height;
          final codec = await descriptor.instantiateCodec(
            targetWidth: landscape && descriptor.width > 128 ? 128 : null,
            targetHeight: !landscape && descriptor.height > 128 ? 128 : null,
          );
          try {
            final frame = await codec.getNextFrame();
            try {
              return (await frame.image.toByteData(
                format: ui.ImageByteFormat.png,
              ))?.buffer.asUint8List();
            } finally {
              frame.image.dispose();
            }
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } finally {
      client.close();
    }
  }
}

class _CachedIcon {
  _CachedIcon({
    required this.source,
    required this.owners,
    required this.lastUsed,
    required this.bytes,
    this.releasedAt,
  });

  final String source;
  final Set<String> owners;
  final int bytes;
  DateTime lastUsed;
  DateTime? releasedAt;
}
