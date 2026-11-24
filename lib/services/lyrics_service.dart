import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/track.dart';

class LyricsService {
  static const _cacheFileName = 'lyrics_cache.json';

  final Map<String, String> _cache = {};
  final Set<String> _sessionMisses = {};
  final Map<String, Future<String?>> _inFlight = {};

  bool _cacheLoaded = false;
  Future<void> _writeQueue = Future.value();

  String _cacheKey(Track track) {
    final artist = track.artist.trim().toLowerCase();
    final title = track.title.trim().toLowerCase();
    return '$artist|$title';
  }

  bool _isUnknownArtist(String artist) {
    final lower = artist.trim().toLowerCase();
    return lower.isEmpty ||
        lower == 'unknown artist' ||
        lower == 'web stream';
  }

  Future<File> _getCacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_cacheFileName');
  }

  Future<void> _ensureCacheLoaded() async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final file = await _getCacheFile();
      if (!file.existsSync()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.key is String && entry.value is String) {
            final value = (entry.value as String).trim();
            if (value.isNotEmpty) {
              _cache[entry.key as String] = value;
            }
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _persistCache() {
    final snapshot = Map<String, String>.from(_cache);
    _writeQueue = _writeQueue.then((_) async {
      try {
        final file = await _getCacheFile();
        if (!file.parent.existsSync()) {
          await file.parent.create(recursive: true);
        }
        const encoder = JsonEncoder.withIndent('  ');
        await file.writeAsString(encoder.convert(snapshot), flush: true);
      } catch (_) {}
    });
    return _writeQueue;
  }

  Future<String?> fetchLyrics(
    Track track, {
    bool forceRefresh = false,
  }) async {
    final existing = track.lyrics?.trim();
    if (!forceRefresh && existing != null && existing.isNotEmpty) {
      return existing;
    }

    final title = track.title.trim();
    if (title.isEmpty || track.id.startsWith('online_soundhelix_')) {
      return null;
    }

    await _ensureCacheLoaded();
    final key = _cacheKey(track);

    if (!forceRefresh) {
      final cached = _cache[key];
      if (cached != null && cached.isNotEmpty) {
        return cached;
      }
      if (_sessionMisses.contains(key)) {
        return null;
      }
    }

    final ongoing = _inFlight[key];
    if (ongoing != null) {
      return ongoing;
    }

    final future = _fetchAndStore(track, key);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<String?> _fetchAndStore(Track track, String key) async {
    final result = await _queryLrcLib(track);
    if (result != null && result.isNotEmpty) {
      _cache[key] = result;
      _sessionMisses.remove(key);
      await _persistCache();
      return result;
    }
    _sessionMisses.add(key);
    return null;
  }

  Future<String?> _queryLrcLib(Track track) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final title = track.title.trim();
      final artist = track.artist.trim();
      final hasArtist = !_isUnknownArtist(artist);
      final album = track.album?.trim();
      final hasAlbum = album != null &&
          album.isNotEmpty &&
          album != 'Custom URL' &&
          album != 'Online Demo';

      // Try 1: Exact /api/get when artist is known
      if (hasArtist) {
        final params = <String, String>{
          'track_name': title,
          'artist_name': artist,
        };
        if (hasAlbum) {
          params['album_name'] = album;
        }
        if (track.duration != null && track.duration!.inSeconds > 0) {
          params['duration'] = track.duration!.inSeconds.toString();
        }
        final getUri = Uri.https('lrclib.net', '/api/get', params);
        final decoded = await _getJson(client, getUri);
        if (decoded is Map) {
          final lyrics = _extractLyrics(Map<String, dynamic>.from(decoded));
          if (lyrics != null) return lyrics;
        }
      }

      // Try 2: Flexible /api/search fallback
      final searchParams = hasArtist
          ? <String, String>{
              'track_name': title,
              'artist_name': artist,
            }
          : <String, String>{'q': title};
      final searchUri = Uri.https('lrclib.net', '/api/search', searchParams);
      final searchResult = await _getJson(client, searchUri);
      if (searchResult is List && searchResult.isNotEmpty) {
        return _pickBestSearchMatch(searchResult, track.duration);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<dynamic> _getJson(HttpClient client, Uri uri) async {
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 7));
      request.headers.set('User-Agent', 'NovenMusicPlayer/1.0');
      request.headers.set('Accept', 'application/json');
      final response = await request.close().timeout(const Duration(seconds: 7));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 7));
      if (body.trim().isEmpty) return null;
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  String? _extractLyrics(Map<String, dynamic> item) {
    final synced = (item['syncedLyrics'] as String? ?? '').trim();
    if (synced.isNotEmpty) return synced;
    final plain = (item['plainLyrics'] as String? ?? '').trim();
    if (plain.isNotEmpty) return plain;
    return null;
  }

  String? _pickBestSearchMatch(List<dynamic> items, Duration? targetDuration) {
    final syncedItems = <Map<String, dynamic>>[];
    String? firstPlain;

    for (final raw in items) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final synced = (map['syncedLyrics'] as String? ?? '').trim();
      final plain = (map['plainLyrics'] as String? ?? '').trim();
      if (synced.isNotEmpty) {
        syncedItems.add(map);
      } else if (firstPlain == null && plain.isNotEmpty) {
        firstPlain = plain;
      }
    }

    if (syncedItems.isNotEmpty) {
      if (targetDuration != null && targetDuration.inSeconds > 0) {
        final targetSec = targetDuration.inSeconds;
        for (final item in syncedItems) {
          final dur = item['duration'];
          if (dur is num && (dur - targetSec).abs() <= 5) {
            return (item['syncedLyrics'] as String).trim();
          }
        }
      }
      return (syncedItems.first['syncedLyrics'] as String).trim();
    }

    return firstPlain;
  }
}
