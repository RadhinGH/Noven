import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/track.dart';
import '../services/cover_cache_service.dart';
import '../services/library_database.dart';
import 'music_source.dart';

class ImportResult {
  final int added;
  final int duplicates;
  final int unsupported;
  final int recovered;

  const ImportResult({
    this.added = 0,
    this.duplicates = 0,
    this.unsupported = 0,
    this.recovered = 0,
  });

  static const empty = ImportResult();

  bool get hasChanges => added > 0 || recovered > 0;
  bool get isEmpty =>
      added == 0 && duplicates == 0 && unsupported == 0 && recovered == 0;

  ImportResult operator +(ImportResult other) {
    return ImportResult(
      added: added + other.added,
      duplicates: duplicates + other.duplicates,
      unsupported: unsupported + other.unsupported,
      recovered: recovered + other.recovered,
    );
  }

  String formatFeedback() {
    if (isEmpty) return 'Tidak ada file baru yang ditambahkan.';
    final parts = <String>[];
    if (added > 0) parts.add('$added lagu ditambahkan');
    if (recovered > 0) parts.add('$recovered lagu dipulihkan');
    if (duplicates > 0) parts.add('$duplicates duplikat dilewati');
    if (unsupported > 0) parts.add('$unsupported format tidak didukung');
    return '${parts.join(' • ')}.';
  }
}

class LocalMusicSource extends MusicSource {
  static const _supportedExts = ['.mp3', '.flac', '.wav', '.ogg', '.opus'];

  final LibraryDatabase _db;
  final CoverCacheService _coverCache;
  final Future<List<String>> Function() _pickFilesFn;
  final Future<Uri?> Function() _pickDirectoryFn;

  final List<Track> _tracks = [];
  final Set<String> _watchedFolders = {};
  bool _isFilePickerBusy = false;

  LocalMusicSource({
    LibraryDatabase? db,
    CoverCacheService? coverCache,
    Future<List<String>> Function()? pickFilesOverride,
    Future<Uri?> Function()? pickDirectoryOverride,
  })  : _db = db ?? LibraryDatabase(),
        _coverCache = coverCache ?? CoverCacheService(),
        _pickFilesFn = pickFilesOverride ?? _defaultPickFiles,
        _pickDirectoryFn = pickDirectoryOverride ?? FilePicker.pickDirectory;

  static Future<List<String>> _defaultPickFiles() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'flac', 'wav', 'ogg', 'opus'],
    );
    return files
        .map((f) => f.path)
        .whereType<String>()
        .where((path) => path.trim().isNotEmpty)
        .toList();
  }

  bool get isFilePickerBusy => _isFilePickerBusy;

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

  bool isSupportedAudioPath(String filePath) {
    final lower = filePath.toLowerCase();
    return _supportedExts.any((ext) => lower.endsWith(ext));
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
  Future<ImportResult> pickFiles() async {
    if (_isFilePickerBusy) return ImportResult.empty;
    _isFilePickerBusy = true;
    try {
      final files = await _pickFilesFn();
      if (files.isEmpty) return ImportResult.empty;
      return await _importFilePaths(files);
    } finally {
      _isFilePickerBusy = false;
    }
  }

  /// Picks a folder, registers it in `watched_folders`, scans recursively,
  /// and persists discovered tracks to SQLite.
  Future<ImportResult> pickFolder() async {
    if (_isFilePickerBusy) return ImportResult.empty;
    _isFilePickerBusy = true;
    try {
      final uri = await _pickDirectoryFn();
      if (uri == null) return ImportResult.empty;

      String folderPath;
      try {
        folderPath = uri.toFilePath();
      } catch (e, st) {
        debugPrint(
          '[LocalMusicSource.pickFolder] Unsupported directory URI ($uri): $e\n$st',
        );
        return ImportResult.empty;
      }

      await _db.addWatchedFolder(folderPath);
      final result = await _scanFolderToDb(folderPath);
      await loadFromDatabase();
      return result;
    } finally {
      _isFilePickerBusy = false;
    }
  }

  /// Imports mixed dropped file and folder paths (for Desktop drag & drop)
  /// with duplicate and unsupported-format detection.
  Future<ImportResult> importDroppedPaths(List<String> paths) async {
    if (paths.isEmpty) return ImportResult.empty;

    final seenInput = <String>{};
    final filePaths = <String>[];
    var totalResult = ImportResult.empty;

    for (final raw in paths) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final normalized = p.normalize(trimmed);
      final key = _pathKey(normalized);
      if (!seenInput.add(key)) {
        totalResult += const ImportResult(duplicates: 1);
        continue;
      }

      if (Directory(normalized).existsSync()) {
        await _db.addWatchedFolder(normalized);
        totalResult += await _scanFolderToDb(normalized);
      } else if (File(normalized).existsSync()) {
        filePaths.add(normalized);
      } else {
        totalResult += const ImportResult(unsupported: 1);
      }
    }

    if (filePaths.isNotEmpty) {
      totalResult += await _importFilePaths(filePaths, reloadAfter: false);
    }

    await loadFromDatabase();
    return totalResult;
  }

  Future<ImportResult> _importFilePaths(
    List<String> paths, {
    bool reloadAfter = true,
  }) async {
    final existingTracks = await _db.getAllTracks(
      sourceType: TrackSourceType.local,
    );
    final byPath = <String, Track>{
      for (final t in existingTracks) _pathKey(t.pathOrUrl): t,
    };

    final toUpsert = <Track>[];
    int added = 0;
    int duplicates = 0;
    int unsupported = 0;
    int recovered = 0;

    for (final path in paths) {
      if (path.trim().isEmpty) continue;
      final normalized = p.normalize(path);
      if (!isSupportedAudioPath(normalized)) {
        unsupported++;
        continue;
      }

      final key = _pathKey(normalized);
      final existing = byPath[key];

      if (existing != null) {
        if (!existing.isAvailable) {
          final refreshed = await buildTrackFromFile(
            normalized,
            existingId: existing.id,
            addedAt: existing.addedAt,
            existingLyrics: existing.lyrics,
            existingTrack: existing,
          );
          byPath[key] = refreshed;
          toUpsert.add(refreshed);
          recovered++;
        } else {
          duplicates++;
        }
        continue;
      }

      final created = await buildTrackFromFile(normalized);
      byPath[key] = created;
      toUpsert.add(created);
      added++;
    }

    if (toUpsert.isNotEmpty) {
      await _db.upsertTracks(toUpsert);
    }
    if (reloadAfter && (toUpsert.isNotEmpty || _tracks.length != byPath.length)) {
      await loadFromDatabase();
    }

    return ImportResult(
      added: added,
      duplicates: duplicates,
      unsupported: unsupported,
      recovered: recovered,
    );
  }

  Future<ImportResult> _scanFolderToDb(
    String folderPath, {
    bool countDuplicates = true,
  }) async {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return ImportResult.empty;

    final audioFiles = <File>[];
    _collectAudioFiles(dir, audioFiles);
    audioFiles.sort((a, b) => a.path.compareTo(b.path));

    final existingByPath = <String, Track>{
      for (final t in await _db.getAllTracks(sourceType: TrackSourceType.local))
        _pathKey(t.pathOrUrl): t,
    };

    final toUpsert = <Track>[];
    int added = 0;
    int duplicates = 0;
    int recovered = 0;

    for (int i = 0; i < audioFiles.length; i++) {
      final file = audioFiles[i];
      final key = _pathKey(file.path);
      final existing = existingByPath[key];
      if (existing != null) {
        if (!existing.isAvailable) {
          final recoveredTrack = await buildTrackFromFile(
            file.path,
            existingId: existing.id,
            addedAt: existing.addedAt,
            existingLyrics: existing.lyrics,
            existingTrack: existing,
          );
          existingByPath[key] = recoveredTrack;
          toUpsert.add(recoveredTrack);
          recovered++;
        } else if (countDuplicates) {
          duplicates++;
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
    return ImportResult(
      added: added,
      duplicates: duplicates,
      recovered: recovered,
    );
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
            existingTrack: track,
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
      final scanRes = await _scanFolderToDb(folder, countDuplicates: false);
      addedCount += scanRes.added;
      recoveredCount += scanRes.recovered;
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
    if (_isFilePickerBusy) return null;
    _isFilePickerBusy = true;
    try {
      final files = await _pickFilesFn();
      if (files.isEmpty) return null;

      final path = files.first;
      if (path.trim().isEmpty) return null;
      return await relocateTrackToPath(trackId, path);
    } finally {
      _isFilePickerBusy = false;
    }
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
      existingTrack: existing,
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
      preserveCustomMetadata: existing.hasCustomMetadata,
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

  /// Updates track title/artist/album overrides in SQLite without touching
  /// the original audio file on disk.
  Future<Track?> editTrackMetadata(
    String trackId, {
    required String title,
    required String artist,
    String? album,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) return null;
    final cleanArtist =
        artist.trim().isEmpty ? 'Unknown Artist' : artist.trim();
    final cleanAlbum =
        (album == null || album.trim().isEmpty) ? null : album.trim();

    await _db.updateTrackMetadata(
      trackId,
      title: cleanTitle,
      artist: cleanArtist,
      album: cleanAlbum,
    );
    await loadFromDatabase();
    return await _db.getTrackById(trackId);
  }

  Future<Track?> setTrackFavorite(String trackId, bool isFavorite) async {
    await _db.setTrackFavorite(trackId, isFavorite);
    await loadFromDatabase();
    return await _db.getTrackById(trackId);
  }

  Future<void> markTrackUnavailable(String trackId) async {
    await _db.setTrackAvailability(trackId, false);
    await loadFromDatabase();
  }

  /// Deletes [trackIds] from SQLite DB ONLY (never deletes files on disk).
  /// Returns cover paths that were associated with deleted tracks so callers
  /// can optionally defer cover cleanup until Undo expires.
  Future<List<String>> removeTracks(
    List<String> trackIds, {
    bool cleanupCovers = false,
  }) async {
    if (trackIds.isEmpty) return const [];

    final candidateCovers = <String>{};
    for (final id in trackIds) {
      final existing = await _db.getTrackById(id);
      final coverPath = existing?.coverPath;
      if (coverPath != null && coverPath.isNotEmpty) {
        candidateCovers.add(coverPath);
      }
    }

    await _db.deleteTracks(trackIds);

    if (cleanupCovers && candidateCovers.isNotEmpty) {
      await cleanupUnreferencedCovers(candidateCovers.toList());
    }

    await loadFromDatabase();
    return candidateCovers.toList();
  }

  Future<void> cleanupUnreferencedCovers(List<String> coverPaths) async {
    for (final coverPath in coverPaths) {
      if (coverPath.isEmpty) continue;
      final stillUsed = await _db.isCoverPathReferenced(coverPath);
      await _coverCache.deleteCoverIfUnreferenced(
        coverPath,
        isStillReferenced: stillUsed,
      );
    }
  }

  Future<void> restoreTracks(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    await _db.upsertTracks(tracks);
    await loadFromDatabase();
  }

  Future<void> removeTrack(String trackId) async {
    await removeTracks([trackId], cleanupCovers: true);
  }

  Future<void> removeFolder(String folderPath) async {
    await _db.removeWatchedFolder(folderPath);
    final affectedCovers = await _db.deleteTracksUnderFolder(folderPath);
    await cleanupUnreferencedCovers(affectedCovers);
    await loadFromDatabase();
  }

  void _collectAudioFiles(Directory dir, List<File> out) {
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          if (isSupportedAudioPath(entity.path)) {
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
    Track? existingTrack,
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

    final keepCustom = existingTrack?.hasCustomMetadata ?? false;

    return Track(
      id: existingId ?? filePath,
      title: keepCustom ? existingTrack!.title : title,
      artist: keepCustom ? existingTrack!.artist : artist,
      album: keepCustom ? existingTrack!.album : album,
      pathOrUrl: filePath,
      sourceType: TrackSourceType.local,
      coverPath: coverPath ?? existingTrack?.coverPath,
      duration: duration ?? existingTrack?.duration,
      lyrics: lyrics ?? existingLyrics,
      addedAt: addedAt ?? DateTime.now(),
      isAvailable: true,
      isFavorite: existingTrack?.isFavorite ?? false,
      hasCustomMetadata: keepCustom,
    );
  }
}
