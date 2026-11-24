import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/playlist.dart';
import '../models/repeat_mode.dart';
import '../models/track.dart';
import '../services/android_media_service.dart';
import '../services/audio_engine.dart';
import '../services/cover_cache_service.dart';
import '../services/library_database.dart';
import '../services/lyrics_service.dart';
import '../services/persistence_guard.dart';
import '../services/storage_service.dart';
import '../sources/local_source.dart';
import '../sources/music_source.dart';
import '../sources/online_source.dart';

class RemoveTracksResult {
  final int count;
  final String? singleTitle;

  const RemoveTracksResult({
    required this.count,
    this.singleTitle,
  });

  String get message => count == 1 && singleTitle != null
      ? '"$singleTitle" dihapus dari Library.'
      : '$count lagu dihapus dari Library.';
}

class _UndoRemoveSnapshot {
  final List<Track> removedTracks;
  final List<String> coverPathsToClean;
  final List<Playlist> previousPlaylists;
  final List<Track> previousPlayQueue;
  final List<Track> previousPlayHistory;
  final Set<String> previousShufflePlayedIds;
  final Track? previousCurrentTrack;
  final int previousPositionMs;

  const _UndoRemoveSnapshot({
    required this.removedTracks,
    required this.coverPathsToClean,
    required this.previousPlaylists,
    required this.previousPlayQueue,
    required this.previousPlayHistory,
    required this.previousShufflePlayedIds,
    required this.previousCurrentTrack,
    required this.previousPositionMs,
  });
}

class LibraryController extends ChangeNotifier {
  final PlaybackBackend _engine;
  final StorageService _storage;
  final LibraryDatabase _libraryDb;
  final LocalMusicSource _localSource;
  final OnlineStreamSource _onlineSource;
  final LyricsService _lyricsService;
  final AndroidMediaService _androidMedia;
  final math.Random _random;
  final Duration _persistInterval;

  late final List<MusicSource> _sources = [_localSource, _onlineSource];
  late final PersistenceGuard _saveGuard;

  void Function(String message)? onStatusMessage;

  Timer? _playbackPersistTimer;
  bool _legacyLibraryMigrated = false;
  bool _allowOverwriteAfterCorrupt = false;
  bool _isBackgroundRescanning = false;
  bool _isPickingFiles = false;
  bool _isLoadingTrack = false;
  bool _isDisposed = false;

  int _playInvocationId = 0;
  String? _loadingTrackId;
  DateTime? _lastPlayStartedAt;

  List<Track> _allTracks = [];
  List<Track> _allKnownTracks = [];
  List<Track> _localTracks = [];
  List<Track> _playQueue = [];
  List<Playlist> _playlists = [];
  Track? _currentTrack;

  bool _shuffle = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.all;
  final List<Track> _playHistory = [];
  final Set<String> _shufflePlayedIds = {};
  final Set<String> _favoriteTrackIds = {};

  int _pendingResumePositionMs = 0;
  final Map<String, String> _fetchedLyrics = {};
  String? _fetchingLyricsTrackId;

  bool _isSelectionMode = false;
  final Set<String> _selectedTrackIds = {};
  _UndoRemoveSnapshot? _pendingUndo;
  String? _lastNotifKey;
  bool _suppressNotificationSync = false;

  LibraryController({
    PlaybackBackend? playback,
    StorageService? storage,
    LibraryDatabase? libraryDb,
    CoverCacheService? coverCache,
    LocalMusicSource? localSource,
    OnlineStreamSource? onlineSource,
    LyricsService? lyricsService,
    AndroidMediaService? androidMedia,
    Duration playbackPersistInterval = const Duration(seconds: 5),
    Duration saveDebounceDuration = const Duration(milliseconds: 450),
    math.Random? random,
    this.onStatusMessage,
  })  : _engine = playback ?? AudioEngine(androidMedia: androidMedia),
        _storage = storage ?? StorageService(),
        _libraryDb = libraryDb ?? LibraryDatabase(),
        _onlineSource = onlineSource ?? OnlineStreamSource(),
        _lyricsService = lyricsService ?? LyricsService(),
        _androidMedia = androidMedia ?? AndroidMediaService(),
        _persistInterval = playbackPersistInterval,
        _random = random ?? math.Random(),
        _localSource = localSource ??
            LocalMusicSource(
              db: libraryDb,
              coverCache: coverCache,
            ) {
    _saveGuard = PersistenceGuard(
      debounceDuration: saveDebounceDuration,
      onSave: _persistState,
    );
    _androidMedia.onMediaAction = _handleAndroidMediaAction;
    _engine.onStateChanged = () {
      if (_isDisposed) return;
      _syncAndroidMediaNotification();
      notifyListeners();
    };
    _engine.onTrackComplete = onTrackComplete;
  }

  PlaybackBackend get engine => _engine;
  AndroidMediaService get androidMedia => _androidMedia;
  bool get isAndroid => _androidMedia.isSupported;
  List<MusicSource> get sources => List.unmodifiable(_sources);
  List<Track> get allTracks => List.unmodifiable(_allTracks);
  List<Track> get allKnownTracks => List.unmodifiable(_allKnownTracks);
  List<Track> get localTracks => List.unmodifiable(_localTracks);
  List<Track> get playQueue => List.unmodifiable(_playQueue);
  List<Playlist> get playlists => List.unmodifiable(_playlists);
  List<Track> get playHistory => List.unmodifiable(_playHistory);
  List<String> get watchedFolders => _localSource.watchedFolders;
  List<CustomStreamEntry> get customStreams => _onlineSource.customStreams;
  Set<String> get favoriteTrackIds => Set.unmodifiable(_favoriteTrackIds);
  Track? get currentTrack => _currentTrack;
  bool get shuffle => _shuffle;
  PlaybackRepeatMode get repeatMode => _repeatMode;
  bool get isLoadingTrack => _isLoadingTrack;
  bool get isPickingFiles => _isPickingFiles;
  bool get isBackgroundRescanning => _isBackgroundRescanning;
  String? get fetchingLyricsTrackId => _fetchingLyricsTrackId;
  bool get isSelectionMode => _isSelectionMode;
  Set<String> get selectedTrackIds => Set.unmodifiable(_selectedTrackIds);
  bool get hasPendingUndo => _pendingUndo != null;
  int get pendingResumePositionMs => _pendingResumePositionMs;
  bool get isPersistenceReady => _saveGuard.isReady;

  Future<void> initialize({bool runBackgroundRescan = true}) async {
    StorageLoadResult loadResult;
    try {
      loadResult = await _storage.loadWithStatus();
    } catch (e, st) {
      debugPrint('[LibraryController.initialize] Storage load failed: $e\n$st');
      loadResult = const StorageLoadResult(
        state: NovenSavedState.defaults,
        status: StorageLoadStatus.notFound,
      );
    }
    if (_isDisposed) return;

    final saved = loadResult.state;
    _legacyLibraryMigrated = saved.legacyLibraryMigrated;

    _engine.applyAudioSettings(volume: saved.volume, isMuted: saved.isMuted);
    _localSource.isEnabled = saved.sourceEnabled['local'] ?? true;
    _onlineSource.isEnabled = saved.sourceEnabled['online'] ?? true;

    _shuffle = saved.shuffle;
    _repeatMode = saved.repeatMode;
    _playlists = List.of(saved.playlists);
    _favoriteTrackIds
      ..clear()
      ..addAll(saved.favoriteTrackIds);
    notifyListeners();

    var shouldPersistAfterInit = false;
    try {
      await _libraryDb.open();
      await _localSource.loadFromDatabase();

      if (!_legacyLibraryMigrated &&
          (saved.localFolders.isNotEmpty || saved.localFiles.isNotEmpty)) {
        await _localSource.migrateLegacyData(
          folders: saved.localFolders,
          files: saved.localFiles,
        );
        _legacyLibraryMigrated = true;
        shouldPersistAfterInit = true;
      } else if (!_legacyLibraryMigrated && saved.schemaVersion < 2) {
        _legacyLibraryMigrated = true;
        shouldPersistAfterInit = true;
      }
    } catch (e, st) {
      debugPrint('[LibraryController.initialize] Library DB init failed: $e\n$st');
    }
    if (_isDisposed) return;

    _onlineSource.restoreCustomStreams(saved.customStreams);
    await refreshSources();
    if (_isDisposed) return;

    try {
      await _engine.init();
    } catch (_) {}
    if (_isDisposed) return;

    if (saved.lastTrackId != null) {
      Track? matched;
      for (final t in _allTracks) {
        if (t.id == saved.lastTrackId) {
          matched = t;
          break;
        }
      }
      if (matched == null) {
        for (final t in _allKnownTracks) {
          if (t.id == saved.lastTrackId) {
            matched = t;
            break;
          }
        }
      }
      if (matched != null) {
        final resolved = _withResolvedTrackState(matched);
        final availableQueue = _allTracks.where((t) => t.isAvailable).toList();
        final resumeQueue = availableQueue.isNotEmpty
            ? _dedupeTracks(availableQueue)
            : [resolved];
        _currentTrack = resolved;
        _playQueue = resumeQueue;
        _pendingResumePositionMs = saved.lastPositionMs;
        _shufflePlayedIds.add(resolved.id);
        _engine.setPreparedTrackState(
          duration: resolved.duration ?? Duration.zero,
          position: Duration(milliseconds: saved.lastPositionMs),
        );
        notifyListeners();
        unawaited(ensureLyricsForTrack(resolved));
      }
    }

    if (_isDisposed) return;
    _saveGuard.markReady();

    if (loadResult.status == StorageLoadStatus.corrupted) {
      onStatusMessage?.call(
        'File pengaturan korup diamankan ke .corrupt — pengaturan aman tidak ditimpa.',
      );
    } else if (loadResult.status == StorageLoadStatus.recoveredFromBackup) {
      onStatusMessage?.call('Pengaturan dipulihkan dari file backup (.bak).');
      await _saveGuard.saveNow();
    } else if (loadResult.status == StorageLoadStatus.migrated ||
        shouldPersistAfterInit) {
      await _saveGuard.saveNow();
    }

    if (_isDisposed) return;
    _playbackPersistTimer?.cancel();
    _playbackPersistTimer = Timer.periodic(_persistInterval, (_) {
      if (_engine.isPlaying && _currentTrack != null) {
        scheduleSave();
      }
    });

    if (runBackgroundRescan) {
      unawaited(this.runBackgroundRescan());
    }
  }

  Future<void> runBackgroundRescan() async {
    if (_isBackgroundRescanning || _isDisposed) return;
    _isBackgroundRescanning = true;
    try {
      await _localSource.rescanInBackground();
      if (_isDisposed) return;
      await refreshSources();
      syncActiveTrackSnapshots();
    } catch (e, st) {
      debugPrint('[LibraryController.runBackgroundRescan] Rescan error: $e\n$st');
    } finally {
      _isBackgroundRescanning = false;
    }
  }

  Future<void> flushOnLifecyclePause() {
    return _saveGuard.saveNow();
  }

  void scheduleSave({bool userAction = false}) {
    if (userAction) {
      _allowOverwriteAfterCorrupt = true;
    }
    _saveGuard.scheduleSave();
  }

  Future<void> saveNow({bool userAction = false}) {
    if (userAction) {
      _allowOverwriteAfterCorrupt = true;
    }
    return _saveGuard.saveNow();
  }

  Future<void> _persistState() {
    final posMs = _engine.hasLoadedSource
        ? _engine.position.inMilliseconds
        : _pendingResumePositionMs;
    return _storage.save(
      NovenSavedState(
        schemaVersion: NovenSavedState.currentSchemaVersion,
        legacyLibraryMigrated: _legacyLibraryMigrated,
        localFolders: _localSource.watchedFolders,
        localFiles: const [],
        customStreams: _onlineSource.customStreams,
        sourceEnabled: {
          for (final s in _sources) s.id: s.isEnabled,
        },
        volume: _engine.volume,
        isMuted: _engine.isMuted,
        shuffle: _shuffle,
        repeatMode: _repeatMode,
        playlists: _playlists,
        favoriteTrackIds: _favoriteTrackIds.toList(),
        lastTrackId: _currentTrack?.id,
        lastPositionMs: posMs < 0 ? 0 : posMs,
      ),
      allowOverwriteCorrupt: _allowOverwriteAfterCorrupt,
    );
  }

  Track _withResolvedTrackState(Track track) {
    var updated = track;
    final existingLyrics = updated.lyrics?.trim();
    if (existingLyrics == null || existingLyrics.isEmpty) {
      final cached = _fetchedLyrics[updated.id];
      if (cached != null && cached.isNotEmpty) {
        updated = updated.copyWith(lyrics: cached);
      }
    }
    if (updated.sourceType == TrackSourceType.stream) {
      final fav = _favoriteTrackIds.contains(updated.id);
      if (updated.isFavorite != fav) {
        updated = updated.copyWith(isFavorite: fav);
      }
    }
    return updated;
  }

  List<Track> _dedupeTracks(List<Track> tracks) {
    final seen = <String>{};
    final result = <Track>[];
    for (final t in tracks) {
      if (seen.add(t.id)) {
        result.add(_withResolvedTrackState(t));
      }
    }
    return result;
  }

  Future<void> refreshSources() async {
    final aggregated = <Track>[];
    final allKnown = <Track>[];
    for (final source in _sources) {
      final tracks = await source.fetchTracks();
      allKnown.addAll(tracks);
      if (source.isEnabled) {
        aggregated.addAll(tracks.where((t) => t.isAvailable));
      }
    }
    final locals = await _localSource.fetchTracks();

    if (_isDisposed) return;
    _allTracks = aggregated.map(_withResolvedTrackState).toList();
    _allKnownTracks = _dedupeTracks(allKnown);
    _localTracks = locals.map(_withResolvedTrackState).toList();
    notifyListeners();
  }

  void syncActiveTrackSnapshots() {
    if (_isDisposed) return;
    final byId = {for (final t in _allKnownTracks) t.id: t};
    if (_currentTrack != null && byId.containsKey(_currentTrack!.id)) {
      _currentTrack = _withResolvedTrackState(byId[_currentTrack!.id]!);
    }
    _playQueue = _playQueue
        .map((t) => byId.containsKey(t.id) ? _withResolvedTrackState(byId[t.id]!) : t)
        .toList();
    for (int i = 0; i < _playHistory.length; i++) {
      final hist = _playHistory[i];
      if (byId.containsKey(hist.id)) {
        _playHistory[i] = _withResolvedTrackState(byId[hist.id]!);
      }
    }
    notifyListeners();
  }

  Future<void> ensureLyricsForTrack(
    Track track, {
    bool forceRefresh = false,
  }) async {
    final existing = track.lyrics?.trim();
    if (!forceRefresh && existing != null && existing.isNotEmpty) return;

    _fetchingLyricsTrackId = track.id;
    notifyListeners();
    try {
      final fetched = await _lyricsService.fetchLyrics(
        track,
        forceRefresh: forceRefresh,
      );
      if (_isDisposed) return;
      if (fetched != null && fetched.isNotEmpty) {
        _fetchedLyrics[track.id] = fetched;
        if (_currentTrack?.id == track.id) {
          _currentTrack = _currentTrack!.copyWith(lyrics: fetched);
        }
        _playQueue = _playQueue
            .map((t) => t.id == track.id ? t.copyWith(lyrics: fetched) : t)
            .toList();
        notifyListeners();
      }
    } finally {
      if (!_isDisposed && _fetchingLyricsTrackId == track.id) {
        _fetchingLyricsTrackId = null;
        notifyListeners();
      }
    }
  }

  // ==================== ADD / IMPORT ====================

  Future<ImportResult> importFiles() async {
    if (_isPickingFiles) return ImportResult.empty;
    _isPickingFiles = true;
    notifyListeners();
    try {
      final result = await _localSource.pickFiles();
      if (result.hasChanges) {
        await refreshSources();
        await saveNow(userAction: true);
      }
      return result;
    } finally {
      if (!_isDisposed) {
        _isPickingFiles = false;
        notifyListeners();
      }
    }
  }

  Future<ImportResult> importFolder() async {
    if (_isPickingFiles) return ImportResult.empty;
    _isPickingFiles = true;
    notifyListeners();
    try {
      final prevFolders = _localSource.watchedFolders.length;
      final result = await _localSource.pickFolder();
      if (result.hasChanges ||
          _localSource.watchedFolders.length > prevFolders) {
        await refreshSources();
        await saveNow(userAction: true);
      }
      return result;
    } finally {
      if (!_isDisposed) {
        _isPickingFiles = false;
        notifyListeners();
      }
    }
  }

  Future<ImportResult> importDroppedPaths(List<String> paths) async {
    final prevFolders = _localSource.watchedFolders.length;
    final result = await _localSource.importDroppedPaths(paths);
    if (result.hasChanges || _localSource.watchedFolders.length > prevFolders) {
      await refreshSources();
      await saveNow(userAction: true);
    }
    return result;
  }

  /// Scans audio from Android MediaStore (requires audio permission already
  /// granted) and merges results into SQLite library.
  Future<ImportResult> scanAndroidDeviceAudio() async {
    if (_isPickingFiles) return ImportResult.empty;
    _isPickingFiles = true;
    notifyListeners();
    try {
      String? coverDirPath;
      try {
        coverDirPath = await _localSource.getCoversDirPath();
      } catch (_) {}

      final items = await _androidMedia.scanDeviceAudio(
        coverDirPath: coverDirPath,
      );
      final result = await _localSource.importAndroidMediaTracks(items);
      if (result.hasChanges || items.isNotEmpty) {
        await refreshSources();
        await saveNow(userAction: true);
      }
      return result;
    } finally {
      if (!_isDisposed) {
        _isPickingFiles = false;
        notifyListeners();
      }
    }
  }

  Future<({int total, int added, int unavailable, int recovered})>
      rescanLocalFolders() async {
    final result = await _localSource.rescanInBackground();
    await refreshSources();
    syncActiveTrackSnapshots();
    await saveNow(userAction: true);
    return result;
  }

  Future<void> removeLocalFolder(String folderPath) async {
    await _localSource.removeFolder(folderPath);
    await refreshSources();
    syncActiveTrackSnapshots();
    await saveNow(userAction: true);
  }

  Future<Track?> locateTrack(Track track) async {
    if (_isPickingFiles) return null;
    _isPickingFiles = true;
    notifyListeners();
    try {
      final updated = await _localSource.relocateTrack(track.id);
      if (updated == null) return null;

      await refreshSources();
      syncActiveTrackSnapshots();
      await saveNow(userAction: true);
      return updated;
    } finally {
      if (!_isDisposed) {
        _isPickingFiles = false;
        notifyListeners();
      }
    }
  }

  Future<bool> addCustomUrl({
    required String title,
    required String artist,
    required String url,
  }) async {
    final added = _onlineSource.addCustomUrl(
      title: title,
      artist: artist,
      url: url,
    );
    if (added) {
      await refreshSources();
      await saveNow(userAction: true);
    }
    return added;
  }

  Future<void> removeCustomUrl(String url) async {
    _onlineSource.removeCustomUrl(url);
    await refreshSources();
    await saveNow(userAction: true);
  }

  Future<void> setSourceEnabled(MusicSource source, bool enabled) async {
    source.isEnabled = enabled;
    await refreshSources();
    await saveNow(userAction: true);
  }

  // ==================== EDIT & FAVORITE ====================

  Future<Track?> editTrackMetadata(
    String trackId, {
    required String title,
    required String artist,
    String? album,
  }) async {
    final updated = await _localSource.editTrackMetadata(
      trackId,
      title: title,
      artist: artist,
      album: album,
    );
    if (updated == null) return null;

    await refreshSources();
    syncActiveTrackSnapshots();
    _syncAndroidMediaNotification(force: true);
    notifyListeners();
    return updated;
  }

  Future<Track?> toggleFavorite(Track track) async {
    final nextFav = !track.isFavorite;
    if (track.sourceType == TrackSourceType.local) {
      final updated = await _localSource.setTrackFavorite(track.id, nextFav);
      if (updated == null) return null;
      await refreshSources();
      syncActiveTrackSnapshots();
      scheduleSave(userAction: true);
      return _allKnownTracks.where((t) => t.id == track.id).isEmpty
          ? updated
          : _allKnownTracks.firstWhere((t) => t.id == track.id);
    } else {
      if (nextFav) {
        _favoriteTrackIds.add(track.id);
      } else {
        _favoriteTrackIds.remove(track.id);
      }
      await refreshSources();
      syncActiveTrackSnapshots();
      await saveNow(userAction: true);
      return _allKnownTracks.where((t) => t.id == track.id).isEmpty
          ? track.copyWith(isFavorite: nextFav)
          : _allKnownTracks.firstWhere((t) => t.id == track.id);
    }
  }

  // ==================== MULTI-SELECT & REMOVE + UNDO ====================

  void enterSelectionMode([String? initialTrackId]) {
    _isSelectionMode = true;
    if (initialTrackId != null) {
      _selectedTrackIds.add(initialTrackId);
    }
    notifyListeners();
  }

  void exitSelectionMode() {
    if (!_isSelectionMode && _selectedTrackIds.isEmpty) return;
    _isSelectionMode = false;
    _selectedTrackIds.clear();
    notifyListeners();
  }

  void toggleTrackSelection(String trackId) {
    if (_selectedTrackIds.contains(trackId)) {
      _selectedTrackIds.remove(trackId);
      if (_selectedTrackIds.isEmpty) {
        _isSelectionMode = false;
      }
    } else {
      _isSelectionMode = true;
      _selectedTrackIds.add(trackId);
    }
    notifyListeners();
  }

  void selectAllTracks(Iterable<Track> tracks) {
    _isSelectionMode = true;
    for (final t in tracks) {
      if (t.sourceType == TrackSourceType.local) {
        _selectedTrackIds.add(t.id);
      }
    }
    notifyListeners();
  }

  /// Removes local [trackIds] from the SQLite library ONLY (never deletes
  /// audio files from disk), cleans playlists/queue/history, advances or
  /// stops playback if current track was removed, and stores a 5s Undo snapshot.
  Future<RemoveTracksResult?> removeTracksFromLibrary(
    List<String> trackIds,
  ) async {
    if (trackIds.isEmpty) return null;
    final removeSet = trackIds.toSet();
    final localById = {for (final t in _localTracks) t.id: t};

    final removedTracks = <Track>[];
    for (final id in trackIds) {
      final track = localById[id];
      if (track != null && !removedTracks.any((r) => r.id == track.id)) {
        removedTracks.add(track);
      }
    }
    if (removedTracks.isEmpty) return null;

    if (_pendingUndo != null) {
      final prevCovers = _pendingUndo!.coverPathsToClean;
      _pendingUndo = null;
      await _localSource.cleanupUnreferencedCovers(prevCovers);
    }

    final previousPlaylists = _playlists
        .map((p) => p.copyWith(trackIds: List<String>.from(p.trackIds)))
        .toList();
    final previousPlayQueue = List<Track>.from(_playQueue);
    final previousPlayHistory = List<Track>.from(_playHistory);
    final previousShufflePlayedIds = Set<String>.from(_shufflePlayedIds);
    final previousCurrentTrack = _currentTrack;
    final wasPlaying = _engine.isPlaying;
    final previousPosMs = _engine.hasLoadedSource
        ? _engine.position.inMilliseconds
        : _pendingResumePositionMs;

    final currentWasRemoved =
        previousCurrentTrack != null && removeSet.contains(previousCurrentTrack.id);

    Track? nextTrackToPlay;
    if (currentWasRemoved && previousPlayQueue.isNotEmpty) {
      final currIdx = previousPlayQueue.indexWhere(
        (t) => t.id == previousCurrentTrack.id,
      );
      final startIdx = currIdx == -1 ? 0 : currIdx + 1;
      for (int offset = 0; offset < previousPlayQueue.length; offset++) {
        final candidate =
            previousPlayQueue[(startIdx + offset) % previousPlayQueue.length];
        if (!removeSet.contains(candidate.id) && candidate.isAvailable) {
          nextTrackToPlay = candidate;
          break;
        }
      }
    }

    _playQueue = _playQueue.where((t) => !removeSet.contains(t.id)).toList();
    _playHistory.removeWhere((t) => removeSet.contains(t.id));
    _shufflePlayedIds.removeAll(removeSet);
    _selectedTrackIds.removeAll(removeSet);
    if (_selectedTrackIds.isEmpty) {
      _isSelectionMode = false;
    }
    _playlists = _playlists
        .map(
          (p) => p.trackIds.any(removeSet.contains)
              ? p.copyWith(
                  trackIds:
                      p.trackIds.where((id) => !removeSet.contains(id)).toList(),
                )
              : p,
        )
        .toList();

    final idsToDelete = removedTracks.map((t) => t.id).toList();
    final candidateCovers = await _localSource.removeTracks(
      idsToDelete,
      cleanupCovers: false,
    );

    _pendingUndo = _UndoRemoveSnapshot(
      removedTracks: removedTracks,
      coverPathsToClean: candidateCovers,
      previousPlaylists: previousPlaylists,
      previousPlayQueue: previousPlayQueue,
      previousPlayHistory: previousPlayHistory,
      previousShufflePlayedIds: previousShufflePlayedIds,
      previousCurrentTrack: previousCurrentTrack,
      previousPositionMs: previousPosMs < 0 ? 0 : previousPosMs,
    );

    await refreshSources();

    if (currentWasRemoved) {
      if (wasPlaying && nextTrackToPlay != null) {
        await playTrack(
          nextTrackToPlay,
          _playQueue,
          recordHistory: false,
        );
      } else {
        await _engine.stop();
        _currentTrack = null;
        _pendingResumePositionMs = 0;
        _syncAndroidMediaNotification(force: true);
      }
    }

    await saveNow(userAction: true);
    notifyListeners();

    return RemoveTracksResult(
      count: removedTracks.length,
      singleTitle: removedTracks.length == 1 ? removedTracks.first.title : null,
    );
  }

  Future<bool> undoLastRemove() async {
    final snap = _pendingUndo;
    if (snap == null) return false;
    _pendingUndo = null;

    await _localSource.restoreTracks(snap.removedTracks);

    _playlists = snap.previousPlaylists;
    _playQueue = snap.previousPlayQueue;
    _playHistory
      ..clear()
      ..addAll(snap.previousPlayHistory);
    _shufflePlayedIds
      ..clear()
      ..addAll(snap.previousShufflePlayedIds);

    await refreshSources();

    if (snap.previousCurrentTrack != null &&
        !_engine.isPlaying &&
        _currentTrack == null) {
      final restored = _withResolvedTrackState(snap.previousCurrentTrack!);
      _currentTrack = restored;
      _pendingResumePositionMs = snap.previousPositionMs;
      _engine.setPreparedTrackState(
        duration: restored.duration ?? Duration.zero,
        position: Duration(milliseconds: snap.previousPositionMs),
      );
    }

    await saveNow(userAction: true);
    notifyListeners();
    return true;
  }

  Future<void> discardPendingUndo() async {
    final snap = _pendingUndo;
    if (snap == null) return;
    _pendingUndo = null;
    await _localSource.cleanupUnreferencedCovers(snap.coverPathsToClean);
  }

  // ==================== PLAYBACK & QUEUE ====================

  Future<void> playTrack(
    Track track,
    List<Track> queue, {
    bool recordHistory = true,
    bool resetShuffleCycle = false,
    Duration? startAt,
  }) async {
    if (!track.isAvailable) {
      onStatusMessage?.call(
        'File "${track.title}" tidak tersedia. Pilih "Locate ulang" di menu lagu.',
      );
      return;
    }

    final resolved = _withResolvedTrackState(track);

    if (_isLoadingTrack && _loadingTrackId == resolved.id) {
      return;
    }
    if (startAt == null &&
        _currentTrack?.id == resolved.id &&
        _engine.isPlaying &&
        _lastPlayStartedAt != null &&
        DateTime.now().difference(_lastPlayStartedAt!) <
            const Duration(milliseconds: 500)) {
      return;
    }

    final invocationId = ++_playInvocationId;
    _loadingTrackId = resolved.id;
    _lastPlayStartedAt = DateTime.now();

    if (recordHistory &&
        _currentTrack != null &&
        _currentTrack!.id != resolved.id) {
      if (_playHistory.length >= 50) {
        _playHistory.removeAt(0);
      }
      _playHistory.add(_currentTrack!);
    }
    if (resetShuffleCycle) {
      _shufflePlayedIds.clear();
    }
    _shufflePlayedIds.add(resolved.id);
    _pendingResumePositionMs = 0;

    _currentTrack = resolved;
    _playQueue = _dedupeTracks(queue);
    _isLoadingTrack = true;
    _syncAndroidMediaNotification(force: true);
    notifyListeners();

    unawaited(saveNow(userAction: true));

    try {
      await _engine.playTrack(resolved, startPosition: startAt);
      if (!_isDisposed && invocationId == _playInvocationId) {
        _syncAndroidMediaNotification(force: true);
        unawaited(ensureLyricsForTrack(resolved));
      }
    } catch (_) {
      if (resolved.sourceType == TrackSourceType.local &&
          !File(resolved.pathOrUrl).existsSync()) {
        await _localSource.markTrackUnavailable(resolved.id);
        await refreshSources();
        syncActiveTrackSnapshots();
      }
      if (!_isDisposed && invocationId == _playInvocationId) {
        onStatusMessage?.call(
          'Gagal memutar "${resolved.title}" — cek file atau koneksi internet.',
        );
      }
    } finally {
      if (!_isDisposed && invocationId == _playInvocationId) {
        _isLoadingTrack = false;
        _loadingTrackId = null;
        if (!_engine.hasLoadedSource) {
          _syncAndroidMediaNotification(force: true);
        }
        notifyListeners();
      }
    }
  }

  void togglePlayPause() {
    if (_isLoadingTrack) return;
    if (_currentTrack == null && _allTracks.isNotEmpty) {
      final firstAvailable = _allTracks.where((t) => t.isAvailable).toList();
      if (firstAvailable.isEmpty) return;
      playTrack(firstAvailable.first, firstAvailable, resetShuffleCycle: true);
      return;
    }
    if (_currentTrack != null && !_engine.hasLoadedSource) {
      final resumePos = Duration(milliseconds: _pendingResumePositionMs);
      final queue = _playQueue.isNotEmpty ? _playQueue : _allTracks;
      playTrack(
        _currentTrack!,
        queue,
        recordHistory: false,
        startAt: resumePos,
      );
      return;
    }
    _engine.togglePause();
    scheduleSave(userAction: true);
  }

  Future<void> onTrackComplete() async {
    if (_currentTrack == null) return;
    if (_repeatMode == PlaybackRepeatMode.one) {
      final replayed = await _engine.replayCurrent();
      if (!replayed && !_isDisposed && _currentTrack != null) {
        await playTrack(_currentTrack!, _playQueue, recordHistory: false);
      }
      return;
    }
    _advanceQueue(allowStopOnEnd: _repeatMode == PlaybackRepeatMode.off);
  }

  void playNext() {
    _advanceQueue(allowStopOnEnd: false);
  }

  void _advanceQueue({required bool allowStopOnEnd}) {
    if (_playQueue.isEmpty || _currentTrack == null) return;

    if (_shuffle) {
      final unplayed = _playQueue
          .where((t) => !_shufflePlayedIds.contains(t.id) && t.isAvailable)
          .toList();
      if (unplayed.isNotEmpty) {
        final picked = unplayed[_random.nextInt(unplayed.length)];
        playTrack(picked, _playQueue);
        return;
      }

      if (allowStopOnEnd) {
        _shufflePlayedIds.clear();
        _engine.resetPosition();
        return;
      }

      _shufflePlayedIds.clear();
      final availableQueue = _playQueue.where((t) => t.isAvailable).toList();
      if (availableQueue.isEmpty) return;
      if (availableQueue.length == 1) {
        playTrack(availableQueue.first, _playQueue, recordHistory: false);
        return;
      }
      final candidates = availableQueue
          .where((t) => t.id != _currentTrack!.id)
          .toList();
      final pool = candidates.isNotEmpty ? candidates : availableQueue;
      final picked = pool[_random.nextInt(pool.length)];
      playTrack(picked, _playQueue);
      return;
    }

    final idx = _playQueue.indexWhere((t) => t.id == _currentTrack!.id);
    if (idx == -1) {
      final first = _playQueue.where((t) => t.isAvailable).toList();
      if (first.isNotEmpty) {
        playTrack(first.first, _playQueue);
      }
      return;
    }
    if (idx + 1 >= _playQueue.length) {
      if (allowStopOnEnd) {
        _engine.resetPosition();
        return;
      }
      final first = _playQueue.where((t) => t.isAvailable).toList();
      if (first.isNotEmpty) {
        playTrack(first.first, _playQueue);
      }
      return;
    }
    playTrack(_playQueue[idx + 1], _playQueue);
  }

  void playPrevious() {
    if (_playQueue.isEmpty || _currentTrack == null) return;

    if (_engine.position > const Duration(seconds: 3)) {
      if (_engine.isPlaying) {
        _engine.seek(Duration.zero);
        _syncAndroidMediaNotification(force: true);
      } else {
        _engine.replayCurrent();
      }
      return;
    }

    if (_shuffle && _playHistory.isNotEmpty) {
      final prevTrack = _playHistory.removeLast();
      playTrack(prevTrack, _playQueue, recordHistory: false);
      return;
    }

    final idx = _playQueue.indexWhere((t) => t.id == _currentTrack!.id);
    final prevIdx = idx == -1
        ? 0
        : (idx - 1 + _playQueue.length) % _playQueue.length;
    playTrack(_playQueue[prevIdx], _playQueue, recordHistory: false);
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    _shufflePlayedIds.clear();
    if (_currentTrack != null) {
      _shufflePlayedIds.add(_currentTrack!.id);
    }
    notifyListeners();
    scheduleSave(userAction: true);
  }

  void cycleRepeatMode() {
    _repeatMode = _repeatMode.next;
    notifyListeners();
    scheduleSave(userAction: true);
  }

  void toggleMute() {
    _engine.toggleMute();
    scheduleSave(userAction: true);
  }

  void setVolume(double value) {
    _engine.setVolume(value);
  }

  void onVolumeChangeEnd() {
    scheduleSave(userAction: true);
  }

  void seekToMs(double valueMs) {
    final target = Duration(milliseconds: valueMs.toInt());
    if (!_engine.hasLoadedSource && _currentTrack != null) {
      _pendingResumePositionMs = target.inMilliseconds;
      _engine.setPreparedTrackState(
        duration: _engine.duration,
        position: target,
      );
      scheduleSave(userAction: true);
    } else {
      _engine.seek(target);
      _syncAndroidMediaNotification(force: true);
      scheduleSave(userAction: true);
    }
  }

  void _syncAndroidMediaNotification({bool force = false}) {
    if (_suppressNotificationSync || !_androidMedia.isSupported || _isDisposed) {
      return;
    }
    final track = _currentTrack;
    if (track == null || (!_engine.hasLoadedSource && !_isLoadingTrack)) {
      if (_lastNotifKey != null || force) {
        _lastNotifKey = null;
        unawaited(_androidMedia.clearMediaNotification());
      }
      return;
    }

    final effectiveIsPlaying = _engine.isPlaying || _isLoadingTrack;
    final effectiveDuration = _engine.duration > Duration.zero
        ? _engine.duration
        : (track.duration ?? Duration.zero);
    final pos = _engine.position;

    final key =
        '${track.id}|${track.title}|${track.artist}|${track.album ?? ''}|${track.coverPath ?? ''}|$effectiveIsPlaying|${effectiveDuration.inMilliseconds}';
    if (!force && _lastNotifKey == key) return;
    _lastNotifKey = key;

    unawaited(
      _androidMedia.updateMediaNotification(
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: effectiveDuration,
        position: pos,
        isPlaying: effectiveIsPlaying,
        coverPath: track.coverPath,
      ),
    );
  }

  void _handleAndroidMediaAction(
    AndroidMediaAction action,
    Duration? seekPosition,
  ) {
    if (_isDisposed) return;
    switch (action) {
      case AndroidMediaAction.play:
        if (!_engine.isPlaying) {
          togglePlayPause();
        }
      case AndroidMediaAction.pause:
        if (_engine.isPlaying) {
          togglePlayPause();
        }
      case AndroidMediaAction.togglePlayPause:
        togglePlayPause();
      case AndroidMediaAction.next:
        playNext();
      case AndroidMediaAction.previous:
        playPrevious();
      case AndroidMediaAction.seek:
        if (seekPosition != null) {
          seekToMs(seekPosition.inMilliseconds.toDouble());
        }
      case AndroidMediaAction.stop:
        if (_engine.isPlaying) {
          _suppressNotificationSync = true;
          try {
            _engine.togglePause();
          } finally {
            _suppressNotificationSync = false;
          }
          scheduleSave(userAction: true);
        }
        _lastNotifKey = null;
        unawaited(_androidMedia.clearMediaNotification());
    }
  }

  void shuffleTracks(List<Track> tracks) {
    final available = tracks.where((t) => t.isAvailable).toList();
    if (available.isEmpty) return;
    _shuffle = true;
    final picked = available[_random.nextInt(available.length)];
    playTrack(picked, available, resetShuffleCycle: true);
    scheduleSave(userAction: true);
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _playQueue.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final item = _playQueue.removeAt(oldIndex);
    _playQueue.insert(newIndex.clamp(0, _playQueue.length), item);
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _playQueue.length) return;
    _playQueue.removeAt(index);
    notifyListeners();
  }

  void clearQueue() {
    _playQueue.clear();
    notifyListeners();
  }

  void insertPlayNext(Track track) {
    final resolved = _withResolvedTrackState(track);
    if (_currentTrack == null) {
      playTrack(resolved, [resolved], resetShuffleCycle: true);
      return;
    }
    if (resolved.id == _currentTrack!.id) {
      onStatusMessage?.call('"${resolved.title}" sedang diputar.');
      return;
    }
    _playQueue.removeWhere((t) => t.id == resolved.id);
    final currentIdx = _playQueue.indexWhere(
      (t) => t.id == _currentTrack!.id,
    );
    final insertIdx = currentIdx == -1 ? 0 : currentIdx + 1;
    _playQueue.insert(insertIdx.clamp(0, _playQueue.length), resolved);
    notifyListeners();
    onStatusMessage?.call('"${resolved.title}" akan diputar berikutnya.');
  }

  void addToQueue(Track track) {
    final resolved = _withResolvedTrackState(track);
    if (_playQueue.every((t) => t.id != resolved.id)) {
      _playQueue.add(resolved);
      notifyListeners();
    }
    onStatusMessage?.call('"${resolved.title}" ditambahkan ke Queue.');
  }

  void addAlbumToQueue(List<Track> tracks) {
    if (tracks.isEmpty) return;
    int added = 0;
    for (final raw in tracks) {
      if (!raw.isAvailable) continue;
      final t = _withResolvedTrackState(raw);
      if (_playQueue.every((q) => q.id != t.id)) {
        _playQueue.add(t);
        added++;
      }
    }
    if (added > 0) notifyListeners();
    onStatusMessage?.call(
      added > 0
          ? '$added lagu ditambahkan ke Queue.'
          : 'Semua lagu sudah ada di Queue.',
    );
  }

  // ==================== PLAYLISTS ====================

  void createPlaylist(
    String name, {
    List<String> initialTrackIds = const [],
  }) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final playlist = Playlist(
      id: 'pl_${DateTime.now().microsecondsSinceEpoch}',
      name: trimmed,
      trackIds: List.of(initialTrackIds),
      createdAt: DateTime.now(),
    );
    _playlists = [..._playlists, playlist];
    notifyListeners();
    saveNow(userAction: true);
    onStatusMessage?.call('Playlist "$trimmed" dibuat.');
  }

  void renamePlaylist(String playlistId, String newName) {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    _playlists = _playlists
        .map((p) => p.id == playlistId ? p.copyWith(name: trimmed) : p)
        .toList();
    notifyListeners();
    saveNow(userAction: true);
  }

  void deletePlaylist(String playlistId) {
    _playlists = _playlists.where((p) => p.id != playlistId).toList();
    notifyListeners();
    saveNow(userAction: true);
  }

  void addTracksToPlaylist(String playlistId, List<String> trackIds) {
    if (trackIds.isEmpty) return;
    _playlists = _playlists.map((p) {
      if (p.id != playlistId) return p;
      final updated = List<String>.from(p.trackIds);
      for (final id in trackIds) {
        if (!updated.contains(id)) updated.add(id);
      }
      return p.copyWith(trackIds: updated);
    }).toList();
    notifyListeners();
    saveNow(userAction: true);
  }

  void removeTrackFromPlaylist(String playlistId, int rawIndex) {
    _playlists = _playlists.map((p) {
      if (p.id != playlistId) return p;
      if (rawIndex < 0 || rawIndex >= p.trackIds.length) return p;
      final updated = List<String>.from(p.trackIds)..removeAt(rawIndex);
      return p.copyWith(trackIds: updated);
    }).toList();
    notifyListeners();
    saveNow(userAction: true);
  }

  void reorderPlaylistTrack(String playlistId, int oldIndex, int newIndex) {
    final knownIds = {for (final t in _allKnownTracks) t.id};
    _playlists = _playlists.map((p) {
      if (p.id != playlistId) return p;
      final visible = p.trackIds.where(knownIds.contains).toList();
      final missing = p.trackIds.where((id) => !knownIds.contains(id));
      if (oldIndex < 0 || oldIndex >= visible.length) return p;
      var target = newIndex;
      if (target > oldIndex) target -= 1;
      final item = visible.removeAt(oldIndex);
      visible.insert(target.clamp(0, visible.length), item);
      return p.copyWith(trackIds: [...visible, ...missing]);
    }).toList();
    notifyListeners();
    saveNow(userAction: true);
  }

  @override
  void dispose() {
    _isDisposed = true;
    ++_playInvocationId;
    if (_androidMedia.isSupported) {
      unawaited(_androidMedia.clearMediaNotification());
    }
    _androidMedia.dispose();
    _playbackPersistTimer?.cancel();
    _playbackPersistTimer = null;
    _saveGuard.flushIfPending();
    _saveGuard.dispose();
    _libraryDb.close();
    _engine.dispose();
    super.dispose();
  }
}
