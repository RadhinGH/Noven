import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/track.dart';

class LibraryDatabase {
  static const _dbFileName = 'noven_library.db';
  static const _dbVersion = 2;
  static bool _ffiInitialized = false;

  final DatabaseFactory? _customFactory;
  final Future<String> Function()? _customDbPathProvider;
  Database? _db;

  LibraryDatabase({
    DatabaseFactory? factory,
    Future<String> Function()? dbPathProvider,
  })  : _customFactory = factory,
        _customDbPathProvider = dbPathProvider;

  bool get isOpen => _db != null && _db!.isOpen;

  static void ensureFfiInitialized() {
    if (_ffiInitialized) return;
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _ffiInitialized = true;
  }

  Future<String> _resolveDbPath() async {
    if (_customDbPathProvider != null) {
      return _customDbPathProvider();
    }
    final dir = await getApplicationSupportDirectory();
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return p.join(dir.path, _dbFileName);
  }

  Future<Database> open() async {
    if (_db != null && _db!.isOpen) return _db!;

    ensureFfiInitialized();
    final dbPath = await _resolveDbPath();
    final factory = _customFactory ?? databaseFactory;

    _db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE tracks (
              id TEXT PRIMARY KEY,
              path_or_uri TEXT NOT NULL,
              title TEXT NOT NULL,
              artist TEXT NOT NULL,
              album TEXT,
              duration_ms INTEGER,
              cover_path TEXT,
              added_at INTEGER NOT NULL,
              is_available INTEGER NOT NULL DEFAULT 1,
              source_type TEXT NOT NULL DEFAULT 'local',
              lyrics TEXT,
              is_favorite INTEGER NOT NULL DEFAULT 0,
              has_custom_metadata INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute(
            'CREATE INDEX idx_tracks_path ON tracks(path_or_uri)',
          );
          await db.execute('''
            CREATE TABLE watched_folders (
              path TEXT PRIMARY KEY,
              added_at INTEGER NOT NULL
            )
          ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE tracks ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0',
            );
            await db.execute(
              'ALTER TABLE tracks ADD COLUMN has_custom_metadata INTEGER NOT NULL DEFAULT 0',
            );
          }
        },
      ),
    );
    return _db!;
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null && db.isOpen) {
      await db.close();
    }
  }

  Future<List<Track>> getAllTracks({TrackSourceType? sourceType}) async {
    final db = await open();
    final rows = await db.query(
      'tracks',
      where: sourceType != null ? 'source_type = ?' : null,
      whereArgs: sourceType != null ? [sourceType.name] : null,
      orderBy: 'added_at ASC, title COLLATE NOCASE ASC',
    );
    return rows.map(_rowToTrack).toList();
  }

  Future<Track?> getTrackById(String id) async {
    final db = await open();
    final rows = await db.query(
      'tracks',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToTrack(rows.first);
  }

  Future<Track?> getTrackByPath(String pathOrUri) async {
    final db = await open();
    final rows = await db.query(
      'tracks',
      where: Platform.isWindows ? 'LOWER(path_or_uri) = LOWER(?)' : 'path_or_uri = ?',
      whereArgs: [pathOrUri],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToTrack(rows.first);
  }

  Future<void> upsertTrack(Track track) async {
    final db = await open();
    await db.insert(
      'tracks',
      _trackToRow(track),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertTracks(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final db = await open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final track in tracks) {
        batch.insert(
          'tracks',
          _trackToRow(track),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> updateTrackMetadata(
    String trackId, {
    required String title,
    required String artist,
    String? album,
  }) async {
    final db = await open();
    await db.update(
      'tracks',
      {
        'title': title,
        'artist': artist,
        'album': album,
        'has_custom_metadata': 1,
      },
      where: 'id = ?',
      whereArgs: [trackId],
    );
  }

  Future<void> setTrackFavorite(String trackId, bool isFavorite) async {
    final db = await open();
    await db.update(
      'tracks',
      {'is_favorite': isFavorite ? 1 : 0},
      where: 'id = ?',
      whereArgs: [trackId],
    );
  }

  Future<void> setTrackAvailability(String id, bool isAvailable) async {
    final db = await open();
    await db.update(
      'tracks',
      {'is_available': isAvailable ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateAvailabilityBatch(Map<String, bool> availabilityById) async {
    if (availabilityById.isEmpty) return;
    final db = await open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in availabilityById.entries) {
        batch.update(
          'tracks',
          {'is_available': entry.value ? 1 : 0},
          where: 'id = ?',
          whereArgs: [entry.key],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Updates the file location and metadata of an existing track while
  /// preserving its [trackId] so playlist entries remain valid.
  Future<void> relocateTrack(
    String trackId, {
    required String newPathOrUri,
    required String title,
    required String artist,
    String? album,
    Duration? duration,
    String? coverPath,
    String? lyrics,
    bool preserveCustomMetadata = false,
  }) async {
    final db = await open();
    final values = <String, Object?>{
      'path_or_uri': newPathOrUri,
      'duration_ms': duration?.inMilliseconds,
      'cover_path': coverPath,
      'lyrics': lyrics,
      'is_available': 1,
    };
    if (!preserveCustomMetadata) {
      values['title'] = title;
      values['artist'] = artist;
      values['album'] = album;
    }
    await db.update(
      'tracks',
      values,
      where: 'id = ?',
      whereArgs: [trackId],
    );
  }

  Future<void> deleteTrack(String id) async {
    final db = await open();
    await db.delete('tracks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteTracks(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final id in ids) {
        batch.delete('tracks', where: 'id = ?', whereArgs: [id]);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<bool> isCoverPathReferenced(String coverPath) async {
    final db = await open();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM tracks WHERE cover_path = ?',
      [coverPath],
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return count > 0;
  }

  Future<List<String>> getWatchedFolders() async {
    final db = await open();
    final rows = await db.query(
      'watched_folders',
      orderBy: 'added_at ASC, path COLLATE NOCASE ASC',
    );
    return rows
        .map((r) => r['path'] as String?)
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .toList();
  }

  Future<void> addWatchedFolder(String folderPath) async {
    final normalized = p.normalize(folderPath);
    final db = await open();
    await db.insert(
      'watched_folders',
      {
        'path': normalized,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> removeWatchedFolder(String folderPath) async {
    final normalized = p.normalize(folderPath);
    final db = await open();
    await db.delete(
      'watched_folders',
      where: Platform.isWindows ? 'LOWER(path) = LOWER(?)' : 'path = ?',
      whereArgs: [normalized],
    );
  }

  Future<List<String>> deleteTracksUnderFolder(String folderPath) async {
    final db = await open();
    final tracks = await getAllTracks(sourceType: TrackSourceType.local);
    final normalizedFolder = p.normalize(folderPath);
    final toDelete = <Track>[];

    for (final track in tracks) {
      final normalizedTrack = p.normalize(track.pathOrUrl);
      final isWithin = Platform.isWindows
          ? p.isWithin(
              normalizedFolder.toLowerCase(),
              normalizedTrack.toLowerCase(),
            )
          : p.isWithin(normalizedFolder, normalizedTrack);
      if (isWithin) {
        toDelete.add(track);
      }
    }

    if (toDelete.isEmpty) return const [];

    final affectedCovers = <String>{};
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final track in toDelete) {
        if (track.coverPath != null && track.coverPath!.isNotEmpty) {
          affectedCovers.add(track.coverPath!);
        }
        batch.delete('tracks', where: 'id = ?', whereArgs: [track.id]);
      }
      await batch.commit(noResult: true);
    });

    return affectedCovers.toList();
  }

  Map<String, dynamic> _trackToRow(Track track) => {
        'id': track.id,
        'path_or_uri': track.pathOrUrl,
        'title': track.title,
        'artist': track.artist,
        'album': track.album,
        'duration_ms': track.duration?.inMilliseconds,
        'cover_path': track.coverPath,
        'added_at': (track.addedAt ?? DateTime.now()).millisecondsSinceEpoch,
        'is_available': track.isAvailable ? 1 : 0,
        'source_type': track.sourceType.name,
        'lyrics': track.lyrics,
        'is_favorite': track.isFavorite ? 1 : 0,
        'has_custom_metadata': track.hasCustomMetadata ? 1 : 0,
      };

  Track _rowToTrack(Map<String, Object?> row) {
    final sourceStr = row['source_type'] as String? ?? 'local';
    final sourceType = sourceStr == TrackSourceType.stream.name
        ? TrackSourceType.stream
        : TrackSourceType.local;
    final durationMs = row['duration_ms'] as int?;
    final addedAtMs = row['added_at'] as int?;
    final isAvailableInt = row['is_available'] as int? ?? 1;
    final isFavoriteInt = row['is_favorite'] as int? ?? 0;
    final hasCustomMetaInt = row['has_custom_metadata'] as int? ?? 0;

    return Track(
      id: row['id'] as String,
      pathOrUrl: row['path_or_uri'] as String,
      title: row['title'] as String,
      artist: row['artist'] as String,
      album: row['album'] as String?,
      duration:
          durationMs != null ? Duration(milliseconds: durationMs) : null,
      coverPath: row['cover_path'] as String?,
      addedAt: addedAtMs != null
          ? DateTime.fromMillisecondsSinceEpoch(addedAtMs)
          : null,
      isAvailable: isAvailableInt != 0,
      sourceType: sourceType,
      lyrics: row['lyrics'] as String?,
      isFavorite: isFavoriteInt != 0,
      hasCustomMetadata: hasCustomMetaInt != 0,
    );
  }
}
