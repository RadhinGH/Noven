import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/track.dart';
import '../services/cover_cache_service.dart';
import '../services/library_database.dart';
import 'music_source.dart';

class LocalMusicSource extends MusicSource {
  static const _supportedExts = ['.mp3', '.flac', '.wav', '.ogg', '.opus'];

  final LibraryDatabase _db;
  final CoverCacheService _coverCache;

  final List<Track> _tracks = [];
  final Set<String> _watchedFolders = {};

  LocalMusicSource({
    LibraryDatabase? db,
    CoverCacheService? coverCache,
  })  : _db = db ?? LibraryDatabase(),
        _coverCache = coverCache ?? CoverCacheService();

  @override
  String get id => 'local';

  @override
  String get name => 'Local Storage';

  @override
  String get description => 'File MP3, FLAC, WAV, OGG dari perangkat kamu';

  List<String> get watchedFolders => List.unmodifiable(_watchedFolders);
  List<String> get savedFolders => watchedFolders;

  @override
  Future<List<Track>> fetchTracks() async => List.unmodifiable(_tracks);

  String _pathKey(String filePath) {
    final normalized = p.normalize(filePath);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  /// Loads persisted local tracks and watched folders straight from SQLite
  /// without scanning audio files on disk.
  Future<void> loadFromDatabase() async {
    final dbTracks = await _db.getAllTracks(sourceType: TrackSourceType.local);
    final dbFolders = await _db.getWatchedFolders();

    _tracks
      ..clear()
      ..addAll(dbTracks);
    _watchedFolders
      ..clear()
      ..addAll(dbFolders);
  }

  /// Migrates legacy `localFolders` and `localFiles` from `noven_data.json`
  /// into SQLite without dropping missing paths or losing playlist references.
  Future<int> migrateLegacyData({
    required List<String> folders,
    required List<String> files,
  }) async {
    final existingTracks = await _db.getAllTracks(
      sourceType: TrackSourceType.local,
    );
    final byPath = <String, Track>{
      for (final t in existingTracks) _pathKey(t.pathOrUrl): t,
    };

    final toUpsert = <Track>[];

    for (final rawFolder in folders) {
      final folderPath = rawFolder.trim();
      if (folderPath.isEmpty) continue;
      await _db.addWatchedFolder(folderPath);

      final dir = Directory(folderPath);
      if (!dir.existsSync()) continue;

      final audioFiles = <File>[];
      _collectAudioFiles(dir, audioFiles);
      audioFiles.sort((a, b) => a.path.compareTo(b.path));

      for (final file in audioFiles) {
        final key = _pathKey(file.path);
        if (byPath.containsKey(key)) continue;
        final track = await buildTrackFromFile(file.path);
        byPath[key] = track;
        toUpsert.add(track);
      }
    }

    for (final rawFile in files) {
      final filePath = rawFile.trim();
      if (filePath.isEmpty) continue;
      final key = _pathKey(filePath);
      if (byPath.containsKey(key)) continue;

      final file = File(filePath);
      final Track track;
      if (file.existsSync()) {
        track = await buildTrackFromFile(filePath);
      } else {
        track = _buildUnavailablePlaceholder(filePath);
      }
      byPath[key] = track;
      toUpsert.add(track);
    }

    if (toUpsert.isNotEmpty) {
      await _db.upsertTracks(toUpsert);
    }

    await loadFromDatabase();
    return toUpsert.length;
  }

  /// Picks one or more local audio files and persists them in SQLite.
  Future<int> pickFiles() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'flac', 'wav', 'ogg', 'opus'],
    );
    if (files.isEmpty) return 0;

    final byPath = <String, Track>{
      for (final t in _tracks) _pathKey(t.pathOrUrl): t,
    };

    final toUpsert = <Track>[];
    int added = 0;

    for (final file in files) {
      final path = file.path;
      if (path == null || path.trim().isEmpty) continue;
      final key = _pathKey(path);
      final existing = byPath[key];

      if (existing != null) {
        if (!existing.isAvailable) {
          final refreshed = await buildTrackFromFile(
            path,
            existingId: existing.id,
            addedAt: existing.addedAt,
          );
          byPath[key] = refreshed;
          toUpsert.add(refreshed);
        }
        continue;
      }

      final created = await buildTrackFromFile(path);
      byPath[key] = created;
      toUpsert.add(created);
      added++;
    }

    if (toUpsert.isNotEmpty) {
      await _db.upsertTracks(toUpsert);
      await loadFromDatabase();
    }
    return added;
  }

  /// Picks a folder, registers it in `watched_folders`, scans recursively,
  /// and persists discovered tracks to SQLite.
  Future<int> pickFolder() async {
    final uri = await FilePicker.pickDirectory();
    if (uri == null) return 0;

    String folderPath;
    try {
      folderPath = uri.toFilePath();
    } catch (e, st) {
      debugPrint(
        '[LocalMusicSource.pickFolder] Unsupported directory URI ($uri): $e\n$st',
      );
      return 0;
    }

    await _db.addWatchedFolder(folderPath);
    final added = await _scanFolderToDb(folderPath);
    await loadFromDatabase();
    return added;
  }

  Future<int> _scanFolderToDb(String folderPath) async {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return 0;

    final audioFiles = <File>[];
    _collectAudioFiles(dir, audioFiles);
    audioFiles.sort((a, b) => a.path.compareTo(b.path));

    final existingByPath = <String, Track>{
      for (final t in await _db.getAllTracks(sourceType: TrackSourceType.local))
        _pathKey(t.pathOrUrl): t,
    };

    final toUpsert = <Track>[];
    int added = 0;

    for (int i = 0; i < audioFiles.length; i++) {
      final file = audioFiles[i];
      final key = _pathKey(file.path);
      final existing = existingByPath[key];
      if (existing != null) {
        if (!existing.isAvailable) {
          final recovered = await buildTrackFromFile(
            file.path,
            existingId: existing.id,
            addedAt: existing.addedAt,
          );
          toUpsert.add(recovered);
        }
        continue;
      }

      final created = await buildTrackFromFile(file.path);
      existingByPath[key] = created;
      toUpsert.add(created);
      added++;

      if (i % 8 == 7) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (toUpsert.isNotEmpty) {
      await _db.upsertTracks(toUpsert);
    }
    return added;
  }

  /// Checks track file availability and metadata in the background and
  /// scans watched folders for new audio files.
  ///
  /// Missing files are marked `isAvailable = false` instead of being deleted.
  Future<({int total, int added, int unavailable, int recovered})>
      rescanInBackground() async {
    final currentTracks = await _db.getAllTracks(
      sourceType: TrackSourceType.local,
    );
    final folders = await _db.getWatchedFolders();

    final availabilityUpdates = <String, bool>{};
    final refreshedTracks = <Track>[];
    int unavailableCount = 0;
    int recoveredCount = 0;

    for (int i = 0; i < currentTracks.length; i++) {
      final track = currentTracks[i];
      final exists = await File(track.pathOrUrl).exists();

      if (!exists) {
        if (track.isAvailable) {
          availabilityUpdates[track.id] = false;
        }
        unavailableCount++;
      } else {
        final coverMissing = track.coverPath != null &&
            track.coverPath!.isNotEmpty &&
            !File(track.coverPath!).existsSync();
        if (!track.isAvailable || coverMissing || track.duration == null) {
          final updated = await buildTrackFromFile(
            track.pathOrUrl,
            existingId: track.id,
            addedAt: track.addedAt,
            existingLyrics: track.lyrics,
          );
          refreshedTracks.add(updated);
          if (!track.isAvailable) {
            recoveredCount++;
          }
        }
      }

      if (i % 8 == 7) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (availabilityUpdates.isNotEmpty) {
      await _db.updateAvailabilityBatch(availabilityUpdates);
    }
    if (refreshedTracks.isNotEmpty) {
      await _db.upsertTracks(refreshedTracks);
    }

    int addedCount = 0;
    for (final folder in folders) {
      addedCount += await _scanFolderToDb(folder);
    }

    await loadFromDatabase();
    return (
      total: _tracks.length,
      added: addedCount,
      unavailable: unavailableCount,
      recovered: recoveredCount,
    );
  }

  /// Opens a file picker to locate a replacement file for [trackId].
  Future<Track?> relocateTrack(String trackId) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'flac', 'wav', 'ogg', 'opus'],
    );
    if (files.isEmpty) return null;

    final path = files.first.path;
    if (path == null || path.trim().isEmpty) return null;
    return relocateTrackToPath(trackId, path);
  }

  /// Relocates [trackId] to [newFilePath] in SQLite while keeping its `id`
  /// intact so playlists referencing this track stay valid.
  Future<Track?> relocateTrackToPath(String trackId, String newFilePath) async {
    final existing = await _db.getTrackById(trackId);
    if (existing == null) return null;

    final oldCoverPath = existing.coverPath;
    final rebuilt = await buildTrackFromFile(
      newFilePath,
      existingId: existing.id,
      addedAt: existing.addedAt,
      existingLyrics: existing.lyrics,
    );

    await _db.relocateTrack(
      trackId,
      newPathOrUri: rebuilt.pathOrUrl,
      title: rebuilt.title,
      artist: rebuilt.artist,
      album: rebuilt.album,
      duration: rebuilt.duration,
      coverPath: rebuilt.coverPath,
      lyrics: rebuilt.lyrics,
    );

    if (oldCoverPath != null && oldCoverPath != rebuilt.coverPath) {
      final stillUsed = await _db.isCoverPathReferenced(oldCoverPath);
      await _coverCache.deleteCoverIfUnreferenced(
        oldCoverPath,
        isStillReferenced: stillUsed,
      );
    }

    await loadFromDatabase();
    return await _db.getTrackById(trackId);
  }

  Future<void> markTrackUnavailable(String trackId) async {
    await _db.setTrackAvailability(trackId, false);
    await loadFromDatabase();
  }

  Future<void> removeTrack(String trackId) async {
    final existing = await _db.getTrackById(trackId);
    await _db.deleteTrack(trackId);

    final coverPath = existing?.coverPath;
    if (coverPath != null && coverPath.isNotEmpty) {
      final stillUsed = await _db.isCoverPathReferenced(coverPath);
      await _coverCache.deleteCoverIfUnreferenced(
        coverPath,
        isStillReferenced: stillUsed,
      );
    }

    await loadFromDatabase();
  }

  Future<void> removeFolder(String folderPath) async {
    await _db.removeWatchedFolder(folderPath);
    final affectedCovers = await _db.deleteTracksUnderFolder(folderPath);
    for (final coverPath in affectedCovers) {
      final stillUsed = await _db.isCoverPathReferenced(coverPath);
      await _coverCache.deleteCoverIfUnreferenced(
        coverPath,
        isStillReferenced: stillUsed,
      );
    }
    await loadFromDatabase();
  }

  void _collectAudioFiles(Directory dir, List<File> out) {
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          final lower = entity.path.toLowerCase();
          if (_supportedExts.any((ext) => lower.endsWith(ext))) {
            out.add(entity);
          }
        } else if (entity is Directory) {
          _collectAudioFiles(entity, out);
        }
      }
    } on FileSystemException {
      // Skip unreadable subfolders so remaining folders continue scanning.
    }
  }

  Track _buildUnavailablePlaceholder(String filePath) {
    final fileName = p.basename(filePath);
    final fallbackTitle = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    return Track(
      id: filePath,
      title: fallbackTitle.isEmpty ? filePath : fallbackTitle,
      artist: 'Unknown Artist',
      pathOrUrl: filePath,
      sourceType: TrackSourceType.local,
      addedAt: DateTime.now(),
      isAvailable: false,
    );
  }

  Future<Track> buildTrackFromFile(
    String filePath, {
    String? existingId,
    DateTime? addedAt,
    String? existingLyrics,
  }) async {
    final fileName = p.basename(filePath);
    final fallbackTitle = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    String title = fallbackTitle;
    String artist = 'Unknown Artist';
    String? album;
    String? coverPath;
    Duration? duration;
    String? lyrics;

    try {
      final metadata = readMetadata(File(filePath), getImage: true);
      if (metadata.title != null && metadata.title!.trim().isNotEmpty) {
        title = metadata.title!.trim();
      }
      if (metadata.artist != null && metadata.artist!.trim().isNotEmpty) {
        artist = metadata.artist!.trim();
      }
      if (metadata.album != null && metadata.album!.trim().isNotEmpty) {
        album = metadata.album!.trim();
      }
      if (metadata.pictures.isNotEmpty) {
        coverPath = await _coverCache.saveCoverBytes(
          metadata.pictures.first.bytes,
        );
      }
      duration = metadata.duration;
      if (metadata.lyrics != null && metadata.lyrics!.trim().isNotEmpty) {
        lyrics = metadata.lyrics!.trim();
      }
    } catch (_) {}

    if (lyrics == null) {
      try {
        final lrcPath = filePath.replaceAll(RegExp(r'\.[^.]+$'), '.lrc');
        final lrcFile = File(lrcPath);
        if (lrcFile.existsSync()) {
          final lrcText = lrcFile.readAsStringSync().trim();
          if (lrcText.isNotEmpty) {
            lyrics = lrcText;
          }
        }
      } catch (_) {}
    }

    return Track(
      id: existingId ?? filePath,
      title: title,
      artist: artist,
      album: album,
      pathOrUrl: filePath,
      sourceType: TrackSourceType.local,
      coverPath: coverPath,
      duration: duration,
      lyrics: lyrics ?? existingLyrics,
      addedAt: addedAt ?? DateTime.now(),
      isAvailable: true,
    );
  }
}
