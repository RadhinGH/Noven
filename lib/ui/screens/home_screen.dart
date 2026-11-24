import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/playlist.dart';
import '../../models/repeat_mode.dart';
import '../../models/track.dart';
import '../../services/audio_engine.dart';
import '../../services/cover_cache_service.dart';
import '../../services/library_database.dart';
import '../../services/lyrics_service.dart';
import '../../services/persistence_guard.dart';
import '../../services/storage_service.dart';
import '../../sources/local_source.dart';
import '../../sources/music_source.dart';
import '../../sources/online_source.dart';
import '../theme/noven_colors.dart';
import '../widgets/album_detail_view.dart';
import '../widgets/audio_visualizer.dart';
import '../widgets/cover_art.dart';
import '../widgets/lyrics_panel.dart';
import '../widgets/nav_rail.dart';
import '../widgets/now_playing_card.dart';
import '../widgets/playlists_view.dart';
import '../widgets/queue_panel.dart';

class _AlbumGroup {
  final String name;
  final String artist;
  final List<Track> tracks;

  const _AlbumGroup({
    required this.name,
    required this.artist,
    required this.tracks,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final AudioEngine _engine = AudioEngine();
  final StorageService _storage = StorageService();
  final LibraryDatabase _libraryDb = LibraryDatabase();
  final CoverCacheService _coverCache = CoverCacheService();
  final LyricsService _lyricsService = LyricsService();
  final math.Random _random = math.Random();

  late final LocalMusicSource _localSource = LocalMusicSource(
    db: _libraryDb,
    coverCache: _coverCache,
  );
  final OnlineStreamSource _onlineSource = OnlineStreamSource();
  late final List<MusicSource> _sources = [_localSource, _onlineSource];
  late final PersistenceGuard _saveGuard = PersistenceGuard(
    onSave: _persistState,
  );

  Timer? _playbackPersistTimer;
  bool _legacyLibraryMigrated = false;
  bool _allowOverwriteAfterCorrupt = false;
  bool _isBackgroundRescanning = false;

  int _selectedMenuIndex = 0; // 0 = Home, 1 = Library, 2 = Playlists, 3 = Sources
  String? _selectedAlbumName;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

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

  int _pendingResumePositionMs = 0;
  final Map<String, String> _fetchedLyrics = {};
  String? _fetchingLyricsTrackId;

  bool _isLoadingTrack = false;
  bool _isSeeking = false;
  double _seekValueMs = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _engine.onStateChanged = () {
      if (mounted) setState(() {});
    };
    _engine.onTrackComplete = _onTrackComplete;
    _initializeApp();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _saveGuard.saveNow();
    }
  }

  Future<void> _initializeApp() async {
    StorageLoadResult loadResult;
    try {
      loadResult = await _storage.loadWithStatus();
    } catch (e, st) {
      debugPrint('[HomeScreen._initializeApp] Storage load failed: $e\n$st');
      loadResult = const StorageLoadResult(
        state: NovenSavedState.defaults,
        status: StorageLoadStatus.notFound,
      );
    }

    final saved = loadResult.state;
    _legacyLibraryMigrated = saved.legacyLibraryMigrated;

    _engine.applyAudioSettings(volume: saved.volume, isMuted: saved.isMuted);
    _localSource.isEnabled = saved.sourceEnabled['local'] ?? true;
    _onlineSource.isEnabled = saved.sourceEnabled['online'] ?? true;

    if (mounted) {
      setState(() {
        _shuffle = saved.shuffle;
        _repeatMode = saved.repeatMode;
        _playlists = List.of(saved.playlists);
      });
    }

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
      debugPrint('[HomeScreen._initializeApp] Library DB init failed: $e\n$st');
    }

    _onlineSource.restoreCustomStreams(saved.customStreams);
    await _refreshSources();

    try {
      await _engine.init();
    } catch (_) {}

    if (saved.lastTrackId != null && mounted) {
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
        final resolved = _withResolvedLyrics(matched);
        final availableQueue = _allTracks.where((t) => t.isAvailable).toList();
        final resumeQueue = availableQueue.isNotEmpty
            ? _dedupeTracks(availableQueue)
            : [resolved];
        setState(() {
          _currentTrack = resolved;
          _playQueue = resumeQueue;
          _pendingResumePositionMs = saved.lastPositionMs;
          _shufflePlayedIds.add(resolved.id);
        });
        _engine.setPreparedTrackState(
          duration: resolved.duration ?? Duration.zero,
          position: Duration(milliseconds: saved.lastPositionMs),
        );
        _ensureLyricsForTrack(resolved);
      }
    }

    if (!mounted) return;
    _saveGuard.markReady();

    if (loadResult.status == StorageLoadStatus.corrupted) {
      _showStatusSnack(
        'File pengaturan korup diamankan ke .corrupt — pengaturan aman tidak ditimpa.',
      );
    } else if (loadResult.status == StorageLoadStatus.recoveredFromBackup) {
      _showStatusSnack('Pengaturan dipulihkan dari file backup (.bak).');
      await _saveGuard.saveNow();
    } else if (loadResult.status == StorageLoadStatus.migrated ||
        shouldPersistAfterInit) {
      await _saveGuard.saveNow();
    }

    _playbackPersistTimer?.cancel();
    _playbackPersistTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_engine.isPlaying && _currentTrack != null) {
        _scheduleSaveState();
      }
    });

    unawaited(_runBackgroundRescan());
  }

  Future<void> _runBackgroundRescan() async {
    if (_isBackgroundRescanning || !mounted) return;
    _isBackgroundRescanning = true;
    try {
      await _localSource.rescanInBackground();
      await _refreshSources();
      if (!mounted) return;
      _syncActiveTrackSnapshots();
    } catch (e, st) {
      debugPrint('[HomeScreen._runBackgroundRescan] Rescan error: $e\n$st');
    } finally {
      _isBackgroundRescanning = false;
    }
  }

  void _syncActiveTrackSnapshots() {
    final byId = {for (final t in _allKnownTracks) t.id: t};
    setState(() {
      if (_currentTrack != null && byId.containsKey(_currentTrack!.id)) {
        _currentTrack = _withResolvedLyrics(byId[_currentTrack!.id]!);
      }
      _playQueue = _playQueue
          .map((t) => byId.containsKey(t.id) ? _withResolvedLyrics(byId[t.id]!) : t)
          .toList();
    });
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
        lastTrackId: _currentTrack?.id,
        lastPositionMs: posMs < 0 ? 0 : posMs,
      ),
      allowOverwriteCorrupt: _allowOverwriteAfterCorrupt,
    );
  }

  void _scheduleSaveState({bool userAction = false}) {
    if (userAction) {
      _allowOverwriteAfterCorrupt = true;
    }
    _saveGuard.scheduleSave();
  }

  Future<void> _saveStateNow({bool userAction = false}) {
    if (userAction) {
      _allowOverwriteAfterCorrupt = true;
    }
    return _saveGuard.saveNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _playbackPersistTimer?.cancel();
    _saveGuard.flushIfPending();
    _saveGuard.dispose();
    _libraryDb.close();
    _searchController.dispose();
    _engine.dispose();
    super.dispose();
  }

  Track _withResolvedLyrics(Track track) {
    final existing = track.lyrics?.trim();
    if (existing != null && existing.isNotEmpty) return track;
    final cached = _fetchedLyrics[track.id];
    if (cached != null && cached.isNotEmpty) {
      return track.copyWith(lyrics: cached);
    }
    return track;
  }

  List<Track> _dedupeTracks(List<Track> tracks) {
    final seen = <String>{};
    final result = <Track>[];
    for (final t in tracks) {
      if (seen.add(t.id)) {
        result.add(_withResolvedLyrics(t));
      }
    }
    return result;
  }

  Future<void> _ensureLyricsForTrack(
    Track track, {
    bool forceRefresh = false,
  }) async {
    final existing = track.lyrics?.trim();
    if (!forceRefresh && existing != null && existing.isNotEmpty) return;

    if (mounted) {
      setState(() => _fetchingLyricsTrackId = track.id);
    }
    try {
      final fetched = await _lyricsService.fetchLyrics(
        track,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      if (fetched != null && fetched.isNotEmpty) {
        _fetchedLyrics[track.id] = fetched;
        setState(() {
          if (_currentTrack?.id == track.id) {
            _currentTrack = _currentTrack!.copyWith(lyrics: fetched);
          }
          _playQueue = _playQueue
              .map((t) => t.id == track.id ? t.copyWith(lyrics: fetched) : t)
              .toList();
        });
      }
    } finally {
      if (mounted && _fetchingLyricsTrackId == track.id) {
        setState(() => _fetchingLyricsTrackId = null);
      }
    }
  }

  Future<void> _refreshSources() async {
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

    if (!mounted) return;
    setState(() {
      _allTracks = aggregated.map(_withResolvedLyrics).toList();
      _allKnownTracks = _dedupeTracks(allKnown);
      _localTracks = locals.map(_withResolvedLyrics).toList();
    });
  }

  Future<void> _importFiles() async {
    final added = await _localSource.pickFiles();
    if (added > 0) {
      await _refreshSources();
      await _saveStateNow(userAction: true);
    }
  }

  Future<void> _importFolder() async {
    final prevFolders = _localSource.watchedFolders.length;
    final added = await _localSource.pickFolder();
    if (added > 0 || _localSource.watchedFolders.length > prevFolders) {
      await _refreshSources();
      await _saveStateNow(userAction: true);
    }
  }

  Future<void> _rescanLocalFolders() async {
    final result = await _localSource.rescanInBackground();
    await _refreshSources();
    _syncActiveTrackSnapshots();
    await _saveStateNow(userAction: true);
    if (!mounted) return;
    final suffix = result.unavailable > 0
        ? ' (${result.unavailable} tidak tersedia)'
        : '';
    _showStatusSnack('Library lokal diperbarui: ${result.total} lagu$suffix.');
  }

  Future<void> _removeLocalFolder(String folderPath) async {
    await _localSource.removeFolder(folderPath);
    await _refreshSources();
    await _saveStateNow(userAction: true);
  }

  Future<void> _locateTrack(Track track) async {
    final updated = await _localSource.relocateTrack(track.id);
    if (updated == null) return;

    await _refreshSources();
    _syncActiveTrackSnapshots();
    await _saveStateNow(userAction: true);
    if (!mounted) return;
    _showStatusSnack('"${updated.title}" berhasil dihubungkan ulang.');
  }

  Future<void> _removeTrackFromLibrary(Track track) async {
    await _localSource.removeTrack(track.id);
    if (!mounted) return;
    setState(() {
      _playQueue = _playQueue.where((t) => t.id != track.id).toList();
      _playlists = _playlists
          .map(
            (p) => p.trackIds.contains(track.id)
                ? p.copyWith(
                    trackIds: p.trackIds.where((id) => id != track.id).toList(),
                  )
                : p,
          )
          .toList();
      if (_currentTrack?.id == track.id && !_engine.hasLoadedSource) {
        _currentTrack = null;
        _pendingResumePositionMs = 0;
      }
    });
    await _refreshSources();
    await _saveStateNow(userAction: true);
    if (!mounted) return;
    _showStatusSnack('"${track.title}" dihapus dari Library.');
  }

  Future<void> _playTrack(
    Track track,
    List<Track> queue, {
    bool recordHistory = true,
    bool resetShuffleCycle = false,
    Duration? startAt,
  }) async {
    if (!track.isAvailable) {
      _showStatusSnack(
        'File "${track.title}" tidak tersedia. Pilih "Locate ulang" di menu lagu.',
      );
      return;
    }

    final resolved = _withResolvedLyrics(track);
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

    setState(() {
      _currentTrack = resolved;
      _playQueue = _dedupeTracks(queue);
      _isSeeking = false;
      _isLoadingTrack = true;
    });

    _saveStateNow(userAction: true);

    try {
      await _engine.playTrack(resolved, startPosition: startAt);
      _ensureLyricsForTrack(resolved);
    } catch (_) {
      if (resolved.sourceType == TrackSourceType.local &&
          !File(resolved.pathOrUrl).existsSync()) {
        await _localSource.markTrackUnavailable(resolved.id);
        await _refreshSources();
        if (mounted) _syncActiveTrackSnapshots();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: NovenColors.surface,
          content: Text(
            'Gagal memutar "${resolved.title}" — cek file atau koneksi internet.',
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoadingTrack = false);
    }
  }

  void _togglePlayPause() {
    if (_isLoadingTrack) return;
    if (_currentTrack == null && _allTracks.isNotEmpty) {
      final firstAvailable = _allTracks.where((t) => t.isAvailable).toList();
      if (firstAvailable.isEmpty) return;
      _playTrack(firstAvailable.first, firstAvailable, resetShuffleCycle: true);
      return;
    }
    if (_currentTrack != null && !_engine.hasLoadedSource) {
      final resumePos = Duration(milliseconds: _pendingResumePositionMs);
      final queue = _playQueue.isNotEmpty ? _playQueue : _allTracks;
      _playTrack(
        _currentTrack!,
        queue,
        recordHistory: false,
        startAt: resumePos,
      );
      return;
    }
    _engine.togglePause();
    _scheduleSaveState(userAction: true);
  }

  Future<void> _onTrackComplete() async {
    if (_currentTrack == null) return;
    if (_repeatMode == PlaybackRepeatMode.one) {
      final replayed = await _engine.replayCurrent();
      if (!replayed && mounted && _currentTrack != null) {
        await _playTrack(_currentTrack!, _playQueue, recordHistory: false);
      }
      return;
    }
    _advanceQueue(allowStopOnEnd: _repeatMode == PlaybackRepeatMode.off);
  }

  void _playNext() {
    _advanceQueue(allowStopOnEnd: false);
  }

  void _advanceQueue({required bool allowStopOnEnd}) {
    if (_playQueue.isEmpty || _currentTrack == null) return;

    if (_shuffle) {
      final unplayed = _playQueue
          .where((t) => !_shufflePlayedIds.contains(t.id))
          .toList();
      if (unplayed.isNotEmpty) {
        final picked = unplayed[_random.nextInt(unplayed.length)];
        _playTrack(picked, _playQueue);
        return;
      }

      if (allowStopOnEnd) {
        _shufflePlayedIds.clear();
        _engine.resetPosition();
        return;
      }

      _shufflePlayedIds.clear();
      if (_playQueue.length == 1) {
        _playTrack(_playQueue.first, _playQueue, recordHistory: false);
        return;
      }
      final candidates = _playQueue
          .where((t) => t.id != _currentTrack!.id)
          .toList();
      final picked = candidates[_random.nextInt(candidates.length)];
      _playTrack(picked, _playQueue);
      return;
    }

    final idx = _playQueue.indexWhere((t) => t.id == _currentTrack!.id);
    if (idx == -1) {
      _playTrack(_playQueue.first, _playQueue);
      return;
    }
    if (idx + 1 >= _playQueue.length) {
      if (allowStopOnEnd) {
        _engine.resetPosition();
        return;
      }
      _playTrack(_playQueue.first, _playQueue);
      return;
    }
    _playTrack(_playQueue[idx + 1], _playQueue);
  }

  void _playPrevious() {
    if (_playQueue.isEmpty || _currentTrack == null) return;

    if (_engine.position > const Duration(seconds: 3)) {
      if (_engine.isPlaying) {
        _engine.seek(Duration.zero);
      } else {
        _engine.replayCurrent();
      }
      return;
    }

    if (_shuffle && _playHistory.isNotEmpty) {
      final prevTrack = _playHistory.removeLast();
      _playTrack(prevTrack, _playQueue, recordHistory: false);
      return;
    }

    final idx = _playQueue.indexWhere((t) => t.id == _currentTrack!.id);
    final prevIdx = idx == -1
        ? 0
        : (idx - 1 + _playQueue.length) % _playQueue.length;
    _playTrack(_playQueue[prevIdx], _playQueue, recordHistory: false);
  }

  void _toggleShuffle() {
    setState(() {
      _shuffle = !_shuffle;
      _shufflePlayedIds.clear();
      if (_currentTrack != null) {
        _shufflePlayedIds.add(_currentTrack!.id);
      }
    });
    _scheduleSaveState(userAction: true);
  }

  void _cycleRepeatMode() {
    setState(() => _repeatMode = _repeatMode.next);
    _scheduleSaveState(userAction: true);
  }

  void _toggleMute() {
    _engine.toggleMute();
    _scheduleSaveState(userAction: true);
  }

  Future<void> _showAddUrlDialog() async {
    final result = await showDialog<({String title, String artist, String url})>(
      context: context,
      builder: (_) => const _AddUrlDialog(),
    );

    if (result != null && result.url.trim().isNotEmpty) {
      final added = _onlineSource.addCustomUrl(
        title: result.title,
        artist: result.artist,
        url: result.url,
      );
      if (added) {
        await _refreshSources();
        await _saveStateNow(userAction: true);
      }
    }
  }

  Future<void> _removeCustomUrl(String url) async {
    _onlineSource.removeCustomUrl(url);
    await _refreshSources();
    await _saveStateNow(userAction: true);
  }

  void _showStatusSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: NovenColors.surface,
        duration: const Duration(seconds: 2),
        content: Text(message, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  void _shuffleTracks(List<Track> tracks) {
    final available = tracks.where((t) => t.isAvailable).toList();
    if (available.isEmpty) return;
    setState(() => _shuffle = true);
    final picked = available[_random.nextInt(available.length)];
    _playTrack(picked, available, resetShuffleCycle: true);
    _scheduleSaveState(userAction: true);
  }

  void _reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _playQueue.length) return;
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _playQueue.removeAt(oldIndex);
      _playQueue.insert(newIndex.clamp(0, _playQueue.length), item);
    });
  }

  void _removeFromQueue(int index) {
    if (index < 0 || index >= _playQueue.length) return;
    setState(() => _playQueue.removeAt(index));
  }

  void _clearQueue() {
    setState(() => _playQueue.clear());
  }

  void _insertPlayNext(Track track) {
    final resolved = _withResolvedLyrics(track);
    if (_currentTrack == null) {
      _playTrack(resolved, [resolved], resetShuffleCycle: true);
      return;
    }
    if (resolved.id == _currentTrack!.id) {
      _showStatusSnack('"${resolved.title}" sedang diputar.');
      return;
    }
    setState(() {
      _playQueue.removeWhere((t) => t.id == resolved.id);
      final currentIdx = _playQueue.indexWhere(
        (t) => t.id == _currentTrack!.id,
      );
      final insertIdx = currentIdx == -1 ? 0 : currentIdx + 1;
      _playQueue.insert(insertIdx.clamp(0, _playQueue.length), resolved);
    });
    _showStatusSnack('"${resolved.title}" akan diputar berikutnya.');
  }

  void _addToQueue(Track track) {
    final resolved = _withResolvedLyrics(track);
    setState(() {
      if (_playQueue.every((t) => t.id != resolved.id)) {
        _playQueue.add(resolved);
      }
    });
    _showStatusSnack('"${resolved.title}" ditambahkan ke Queue.');
  }

  void _addAlbumToQueue(List<Track> tracks) {
    if (tracks.isEmpty) return;
    int added = 0;
    setState(() {
      for (final raw in tracks) {
        final t = _withResolvedLyrics(raw);
        if (_playQueue.every((q) => q.id != t.id)) {
          _playQueue.add(t);
          added++;
        }
      }
    });
    _showStatusSnack(
      added > 0
          ? '$added lagu ditambahkan ke Queue.'
          : 'Semua lagu sudah ada di Queue.',
    );
  }

  Future<void> _openQueueSheet() {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: NovenColors.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sheetCtx).size.height * 0.65,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: QueuePanel(
                playQueue: _playQueue,
                allTracks: _allTracks,
                currentTrackId: _currentTrack?.id,
                showModeSwitcher: false,
                onPlayFromQueue: (track) {
                  Navigator.of(sheetCtx).pop();
                  _playTrack(track, _playQueue);
                },
                onPlayFromAllTracks: (track, list) {
                  Navigator.of(sheetCtx).pop();
                  _playTrack(track, list, resetShuffleCycle: true);
                },
                onReorderQueue: _reorderQueue,
                onRemoveFromQueue: _removeFromQueue,
                onClearQueue: _clearQueue,
                onPlayNext: _insertPlayNext,
                onAddToQueue: _addToQueue,
                onAddToPlaylist: _promptAddTrackToPlaylist,
              ),
            ),
          ),
        );
      },
    );
  }

  void _createPlaylist(
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
    setState(() => _playlists = [..._playlists, playlist]);
    _saveStateNow(userAction: true);
    _showStatusSnack('Playlist "$trimmed" dibuat.');
  }

  void _renamePlaylist(String playlistId, String newName) {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _playlists = _playlists
          .map((p) => p.id == playlistId ? p.copyWith(name: trimmed) : p)
          .toList();
    });
    _saveStateNow(userAction: true);
  }

  void _deletePlaylist(String playlistId) {
    setState(() {
      _playlists = _playlists.where((p) => p.id != playlistId).toList();
    });
    _saveStateNow(userAction: true);
  }

  void _addTracksToPlaylist(String playlistId, List<String> trackIds) {
    if (trackIds.isEmpty) return;
    setState(() {
      _playlists = _playlists.map((p) {
        if (p.id != playlistId) return p;
        final updated = List<String>.from(p.trackIds);
        for (final id in trackIds) {
          if (!updated.contains(id)) updated.add(id);
        }
        return p.copyWith(trackIds: updated);
      }).toList();
    });
    _saveStateNow(userAction: true);
  }

  void _removeTrackFromPlaylist(String playlistId, int rawIndex) {
    setState(() {
      _playlists = _playlists.map((p) {
        if (p.id != playlistId) return p;
        if (rawIndex < 0 || rawIndex >= p.trackIds.length) return p;
        final updated = List<String>.from(p.trackIds)..removeAt(rawIndex);
        return p.copyWith(trackIds: updated);
      }).toList();
    });
    _saveStateNow(userAction: true);
  }

  void _reorderPlaylistTrack(String playlistId, int oldIndex, int newIndex) {
    final knownIds = {for (final t in _allKnownTracks) t.id};
    setState(() {
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
    });
    _saveStateNow(userAction: true);
  }

  Future<void> _promptAddTrackToPlaylist(Track track) {
    return showAddToPlaylistDialog(
      context: context,
      track: track,
      playlists: _playlists,
      onAddToExisting: (playlist) {
        _addTracksToPlaylist(playlist.id, [track.id]);
        _showStatusSnack('"${track.title}" ditambahkan ke "${playlist.name}".');
      },
      onCreateAndAdd: (newName) {
        _createPlaylist(newName, initialTrackIds: [track.id]);
      },
    );
  }

  String _folderDisplayName(String folderPath) {
    final parts = folderPath
        .split(Platform.pathSeparator)
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? folderPath : parts.last;
  }

  String _greetingText() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  List<_AlbumGroup> _groupAlbums(List<Track> tracks) {
    final map = <String, List<Track>>{};
    for (final t in tracks) {
      final key = (t.album != null && t.album!.trim().isNotEmpty)
          ? t.album!.trim()
          : t.title;
      map.putIfAbsent(key, () => []).add(t);
    }
    return map.entries
        .map(
          (e) => _AlbumGroup(
            name: e.key,
            artist: e.value.first.artist,
            tracks: e.value,
          ),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 860;
        final isTallEnough = constraints.maxHeight >= 560;

        return Scaffold(
          backgroundColor: NovenColors.bg,
          body: Row(
            children: [
              if (isDesktop)
                NovenNavRail(
                  selectedIndex: _selectedMenuIndex,
                  onSelect: (i) => setState(() {
                    _selectedMenuIndex = i;
                    _selectedAlbumName = null;
                  }),
                  onImportFolder: _importFolder,
                  onImportFiles: _importFiles,
                  onAddUrl: _showAddUrlDialog,
                ),
              Expanded(
                child: _buildActivePage(
                  isDesktop: isDesktop,
                  isTallEnough: isTallEnough,
                ),
              ),
            ],
          ),
          bottomNavigationBar: isDesktop
              ? null
              : NavigationBar(
                  selectedIndex: _selectedMenuIndex,
                  backgroundColor: NovenColors.surface,
                  indicatorColor: NovenColors.accent.withValues(alpha: 0.35),
                  onDestinationSelected: (index) {
                    setState(() {
                      _selectedMenuIndex = index;
                      _selectedAlbumName = null;
                    });
                  },
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.home_rounded),
                      label: 'Home',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.library_music_rounded),
                      label: 'Library',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.queue_music_rounded),
                      label: 'Playlists',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.hub_rounded),
                      label: 'Sources',
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildActivePage({
    required bool isDesktop,
    required bool isTallEnough,
  }) {
    switch (_selectedMenuIndex) {
      case 0:
        return _buildHomeTab(isDesktop: isDesktop, isTallEnough: isTallEnough);
      case 1:
        return _buildLibraryTab(isDesktop: isDesktop);
      case 2:
        return _buildPlaylistsTab(isDesktop: isDesktop);
      default:
        return _buildSourcesTab(isDesktop: isDesktop);
    }
  }

  // ==================== TAB 0: HOME (KONSEP A TWEAKED) ====================
  Widget _buildHomeTab({
    required bool isDesktop,
    required bool isTallEnough,
  }) {
    final query = _searchQuery.toLowerCase();
    final visibleTracks = query.isEmpty
        ? _allTracks
        : _allTracks.where((t) {
            return t.title.toLowerCase().contains(query) ||
                t.artist.toLowerCase().contains(query) ||
                (t.album?.toLowerCase().contains(query) ?? false);
          }).toList();
    final albums = _groupAlbums(visibleTracks);

    _AlbumGroup? selectedAlbum;
    if (_selectedAlbumName != null) {
      for (final a in _groupAlbums(_allTracks)) {
        if (a.name == _selectedAlbumName) {
          selectedAlbum = a;
          break;
        }
      }
      if (selectedAlbum == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedAlbumName != null) {
            setState(() => _selectedAlbumName = null);
          }
        });
      }
    }

    if (selectedAlbum != null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          isDesktop ? 26 : 16,
          isDesktop ? 20 : 14,
          isDesktop ? 26 : 16,
          isDesktop ? 20 : 12,
        ),
        child: Column(
          children: [
            Expanded(
              child: AlbumDetailView(
                albumName: selectedAlbum.name,
                artist: selectedAlbum.artist,
                tracks: selectedAlbum.tracks,
                currentTrackId: _currentTrack?.id,
                isPlaying: _engine.isPlaying,
                onBack: () => setState(() => _selectedAlbumName = null),
                onPlayTrack: (track, queue) => _playTrack(
                  track,
                  queue,
                  resetShuffleCycle: true,
                ),
                onShuffleAlbum: _shuffleTracks,
                onAddAlbumToQueue: _addAlbumToQueue,
                onPlayNext: _insertPlayNext,
                onAddToQueue: _addToQueue,
                onAddToPlaylist: _promptAddTrackToPlaylist,
              ),
            ),
            const SizedBox(height: 12),
            _buildNowPlayingCard(),
          ],
        ),
      );
    }

    final isFetchingCurrentLyrics =
        _currentTrack != null && _fetchingLyricsTrackId == _currentTrack!.id;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 14,
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 12,
      ),
      child: Column(
        children: [
          _buildTopHeader(isDesktop: isDesktop),
          const SizedBox(height: 18),
          Expanded(
            child: (isDesktop && isTallEnough)
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Kolom Kiri: Hero Banner + Your Albums + Now Playing Card
                      Expanded(
                        flex: 13,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildHeroBanner(),
                            const SizedBox(height: 16),
                            _buildAlbumsSection(albums),
                            const Spacer(),
                            const SizedBox(height: 12),
                            _buildNowPlayingCard(),
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),

                      // Kolom Kanan: Queue/All Tracks + Lyrics / Album Cover Card
                      Expanded(
                        flex: 8,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 4,
                              child: QueuePanel(
                                playQueue: _playQueue,
                                allTracks: visibleTracks,
                                currentTrackId: _currentTrack?.id,
                                isSearchActive: _searchQuery.trim().isNotEmpty,
                                initialShowQueue: _playQueue.isNotEmpty,
                                onPlayFromQueue: (track) =>
                                    _playTrack(track, _playQueue),
                                onPlayFromAllTracks: (track, list) =>
                                    _playTrack(
                                      track,
                                      list,
                                      resetShuffleCycle: true,
                                    ),
                                onReorderQueue: _reorderQueue,
                                onRemoveFromQueue: _removeFromQueue,
                                onClearQueue: _clearQueue,
                                onPlayNext: _insertPlayNext,
                                onAddToQueue: _addToQueue,
                                onAddToPlaylist: _promptAddTrackToPlaylist,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              flex: 6,
                              child: LyricsPanel(
                                track: _currentTrack,
                                positionListenable: _engine.positionNotifier,
                                onSeek: _engine.seek,
                                isFetching: isFetchingCurrentLyrics,
                                onRefreshLyrics: _currentTrack == null
                                    ? null
                                    : () => _ensureLyricsForTrack(
                                        _currentTrack!,
                                        forceRefresh: true,
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeroBanner(),
                        const SizedBox(height: 16),
                        _buildAlbumsSection(albums),
                        const SizedBox(height: 16),
                        SizedBox(
                          height: 240,
                          child: QueuePanel(
                            playQueue: _playQueue,
                            allTracks: visibleTracks,
                            currentTrackId: _currentTrack?.id,
                            isSearchActive: _searchQuery.trim().isNotEmpty,
                            initialShowQueue: _playQueue.isNotEmpty,
                            onPlayFromQueue: (track) =>
                                _playTrack(track, _playQueue),
                            onPlayFromAllTracks: (track, list) => _playTrack(
                              track,
                              list,
                              resetShuffleCycle: true,
                            ),
                            onReorderQueue: _reorderQueue,
                            onRemoveFromQueue: _removeFromQueue,
                            onClearQueue: _clearQueue,
                            onPlayNext: _insertPlayNext,
                            onAddToQueue: _addToQueue,
                            onAddToPlaylist: _promptAddTrackToPlaylist,
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          height: 280,
                          child: LyricsPanel(
                            track: _currentTrack,
                            positionListenable: _engine.positionNotifier,
                            onSeek: _engine.seek,
                            isFetching: isFetchingCurrentLyrics,
                            onRefreshLyrics: _currentTrack == null
                                ? null
                                : () => _ensureLyricsForTrack(
                                    _currentTrack!,
                                    forceRefresh: true,
                                  ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildNowPlayingCard(),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopHeader({required bool isDesktop}) {
    final searchField = Container(
      width: isDesktop ? 300 : double.infinity,
      height: 40,
      decoration: BoxDecoration(
        color: NovenColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (val) => setState(() => _searchQuery = val),
        style: const TextStyle(fontSize: 13.5, color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Search',
          hintStyle: TextStyle(
            fontSize: 13.5,
            color: NovenColors.silver.withValues(alpha: 0.55),
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 18,
            color: NovenColors.silver.withValues(alpha: 0.65),
          ),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: NovenColors.silver,
                  ),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );

    final greeting = RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 20),
        children: [
          TextSpan(
            text: '${_greetingText()}, ',
            style: TextStyle(
              color: NovenColors.silver.withValues(alpha: 0.8),
              fontWeight: FontWeight.w400,
            ),
          ),
          const TextSpan(
            text: 'Noven',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );

    if (!isDesktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              greeting,
              const Spacer(),
              IconButton(
                tooltip: 'Import Folder',
                icon: const Icon(
                  Icons.folder_open_rounded,
                  color: NovenColors.silver,
                ),
                onPressed: _importFolder,
              ),
              IconButton(
                tooltip: 'Tambah Lagu',
                icon: const Icon(Icons.add_rounded, color: NovenColors.silver),
                onPressed: _importFiles,
              ),
            ],
          ),
          const SizedBox(height: 10),
          searchField,
        ],
      );
    }

    return Row(
      children: [
        greeting,
        const Spacer(),
        searchField,
      ],
    );
  }

  Widget _buildHeroBanner() {
    final track = _currentTrack ?? (_allTracks.isNotEmpty ? _allTracks.first : null);
    final isOnline = track?.sourceType == TrackSourceType.stream;

    return Container(
      height: 190,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            NovenColors.accent,
            Color(0xFF473C78),
            NovenColors.surface,
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: NovenColors.accent.withValues(alpha: 0.25),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            // Artwork kanan pudar halus ke kiri
            if ((track?.coverPath != null && track!.coverPath!.isNotEmpty) ||
                (track?.coverUrl != null && track!.coverUrl!.isNotEmpty))
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 240,
                child: ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Colors.transparent, Colors.black],
                  ).createShader(rect),
                  blendMode: BlendMode.dstIn,
                  child: Opacity(
                    opacity: 0.55,
                    child:
                        track.coverPath != null && track.coverPath!.isNotEmpty
                        ? Image.file(
                            File(track.coverPath!),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          )
                        : Image.network(
                            track.coverUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                  ),
                ),
              )
            else
              Positioned(
                right: -30,
                top: -30,
                child: Container(
                  width: 190,
                  height: 190,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        NovenColors.silver.withValues(alpha: 0.22),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),

            // Konten Hero + Real-Time FFT Visualizer
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _currentTrack != null ? 'Now Playing' : 'Featured',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (track != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: NovenColors.bg.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isOnline
                                    ? Icons.cloud_rounded
                                    : Icons.graphic_eq_rounded,
                                size: 12,
                                color: NovenColors.silver,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isOnline ? 'Stream' : 'Local Audio',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: NovenColors.silver,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    track?.title ?? 'Welcome to Noven',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    track != null
                        ? '${track.artist}${track.album != null ? ' • ${track.album}' : ''}'
                        : 'Import your local music folder or stream online tracks',
                    style: TextStyle(
                      fontSize: 13,
                      color: NovenColors.silver.withValues(alpha: 0.9),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  AudioVisualizer(
                    fftListenable: _engine.fftNotifier,
                    primaryColor: NovenColors.accentLight,
                    secondaryColor: NovenColors.silver,
                    barCount: 44,
                    height: 52,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumsSection(List<_AlbumGroup> albums) {
    final currentAlbumKey = _currentTrack == null
        ? null
        : ((_currentTrack!.album != null &&
                  _currentTrack!.album!.trim().isNotEmpty)
              ? _currentTrack!.album!.trim()
              : _currentTrack!.title);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Your Albums',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => _selectedMenuIndex = 1),
              child: Text(
                'See All',
                style: TextStyle(
                  fontSize: 12.5,
                  color: NovenColors.silver.withValues(alpha: 0.75),
                ),
              ),
            ),
          ],
        ),
        SizedBox(
          height: 152,
          child: albums.isEmpty
              ? Center(
                  child: Text(
                    'Belum ada album — klik + di kiri bawah untuk Import Folder',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: NovenColors.silver.withValues(alpha: 0.6),
                    ),
                  ),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 6,
                  ),
                  itemCount: albums.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 16),
                  itemBuilder: (context, index) {
                    final album = albums[index];
                    final isFeatured = currentAlbumKey != null
                        ? album.name == currentAlbumKey
                        : index == 0;

                    final card = GestureDetector(
                      onTap: () =>
                          setState(() => _selectedAlbumName = album.name),
                      child: Container(
                        width: 136,
                        height: 136,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: NovenColors.surface,
                          border: Border.all(
                            color: isFeatured
                                ? NovenColors.accentLight.withValues(alpha: 0.7)
                                : Colors.white.withValues(alpha: 0.08),
                            width: isFeatured ? 1.5 : 1,
                          ),
                          boxShadow: isFeatured
                              ? [
                                  BoxShadow(
                                    color: NovenColors.accent.withValues(
                                      alpha: 0.55,
                                    ),
                                    blurRadius: 20,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(19),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CoverArt(
                                track: album.tracks.first,
                                size: 136,
                                radius: 19,
                              ),
                              // Scrim gelap bawah agar teks album terbaca jelas
                              Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black.withValues(alpha: 0.82),
                                    ],
                                  ),
                                ),
                              ),
                              if (isFeatured)
                                Positioned(
                                  top: 8,
                                  right: 8,
                                  child: Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: NovenColors.accent,
                                      boxShadow: [
                                        BoxShadow(
                                          color: NovenColors.accent.withValues(
                                            alpha: 0.65,
                                          ),
                                          blurRadius: 10,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              Positioned(
                                left: 10,
                                right: 10,
                                bottom: 10,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      album.name,
                                      style: const TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${album.artist} • ${album.tracks.length} track',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: NovenColors.silver.withValues(
                                          alpha: 0.85,
                                        ),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );

                    return isFeatured
                        ? Transform.rotate(angle: -0.055, child: card)
                        : card;
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildNowPlayingCard() {
    return NowPlayingCard(
      track: _currentTrack,
      isPlaying: _engine.isPlaying,
      isLoading: _isLoadingTrack,
      positionListenable: _engine.positionNotifier,
      duration: _engine.duration,
      isSeeking: _isSeeking,
      seekValueMs: _seekValueMs,
      volume: _engine.volume,
      isMuted: _engine.isMuted,
      isShuffle: _shuffle,
      repeatMode: _repeatMode,
      onTogglePlay: _togglePlayPause,
      onPrev: _playPrevious,
      onNext: _playNext,
      onToggleShuffle: _toggleShuffle,
      onCycleRepeat: _cycleRepeatMode,
      onSeekStart: (value) {
        setState(() {
          _isSeeking = true;
          _seekValueMs = value;
        });
      },
      onSeekChange: (value) {
        setState(() => _seekValueMs = value);
      },
      onSeekEnd: (value) {
        final target = Duration(milliseconds: value.toInt());
        if (!_engine.hasLoadedSource && _currentTrack != null) {
          _pendingResumePositionMs = target.inMilliseconds;
          _engine.setPreparedTrackState(
            duration: _engine.duration,
            position: target,
          );
          _scheduleSaveState(userAction: true);
        } else {
          _engine.seek(target);
          _scheduleSaveState(userAction: true);
        }
        setState(() => _isSeeking = false);
      },
      onVolumeChange: _engine.setVolume,
      onVolumeChangeEnd: (_) => _scheduleSaveState(userAction: true),
      onToggleMute: _toggleMute,
      onOpenQueue: _openQueueSheet,
      queueCount: _playQueue.length,
    );
  }

  // ==================== TAB 1: LIBRARY (LOKAL) ====================
  Widget _buildLibraryTab({required bool isDesktop}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 14,
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Library',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '${_localTracks.length} lagu lokal tersimpan',
                      style: TextStyle(
                        fontSize: 13,
                        color: NovenColors.silver.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _importFolder,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('Import Folder'),
                    ),
                    FilledButton.icon(
                      onPressed: _importFiles,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Tambah Lagu'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _localTracks.isEmpty
                ? Center(
                    child: Text(
                      'Belum ada lagu lokal.\nKlik "Import Folder" untuk memasukkan album (MP3/FLAC/WAV/OGG).',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: NovenColors.silver.withValues(alpha: 0.7),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _localTracks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final track = _localTracks[index];
                      final isCurrent = _currentTrack?.id == track.id;

                      return Opacity(
                        opacity: track.isAvailable ? 1.0 : 0.62,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => _playTrack(
                            track,
                            _localTracks.where((t) => t.isAvailable).toList(),
                            resetShuffleCycle: true,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? NovenColors.accent.withValues(alpha: 0.22)
                                  : NovenColors.surface,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: !track.isAvailable
                                    ? Colors.amber.withValues(alpha: 0.45)
                                    : isCurrent
                                    ? NovenColors.accentLight.withValues(
                                        alpha: 0.7,
                                      )
                                    : Colors.white.withValues(alpha: 0.05),
                              ),
                            ),
                            child: Row(
                              children: [
                                CoverArt(track: track, size: 44, radius: 10),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        track.title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        track.album != null
                                            ? '${track.artist} • ${track.album}'
                                            : track.artist,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: NovenColors.silver.withValues(
                                            alpha: 0.75,
                                          ),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                if (!track.isAvailable)
                                  Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.amber.withValues(
                                        alpha: 0.16,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: Colors.amber.withValues(
                                          alpha: 0.45,
                                        ),
                                      ),
                                    ),
                                    child: const Text(
                                      'Tidak tersedia',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.amberAccent,
                                      ),
                                    ),
                                  ),
                                if (track.isAvailable && track.lyrics != null)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 10),
                                    child: Icon(
                                      Icons.lyrics_rounded,
                                      size: 16,
                                      color: NovenColors.accentLight,
                                    ),
                                  ),
                                if (track.duration != null)
                                  Text(
                                    _formatDuration(track.duration!),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: NovenColors.silver.withValues(
                                        alpha: 0.75,
                                      ),
                                    ),
                                  ),
                                PopupMenuButton<String>(
                                  tooltip: 'Opsi Lagu',
                                  icon: Icon(
                                    Icons.more_vert_rounded,
                                    size: 18,
                                    color: NovenColors.silver.withValues(
                                      alpha: 0.75,
                                    ),
                                  ),
                                  color: NovenColors.surface,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: 0.08,
                                      ),
                                    ),
                                  ),
                                  onSelected: (value) {
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          if (!mounted) return;
                                          switch (value) {
                                            case 'locate':
                                              _locateTrack(track);
                                            case 'next':
                                              _insertPlayNext(track);
                                            case 'queue':
                                              _addToQueue(track);
                                            case 'playlist':
                                              _promptAddTrackToPlaylist(track);
                                            case 'remove':
                                              _removeTrackFromLibrary(track);
                                          }
                                        });
                                  },
                                  itemBuilder: (_) => track.isAvailable
                                      ? const [
                                          PopupMenuItem(
                                            value: 'next',
                                            child: Text('Play Next'),
                                          ),
                                          PopupMenuItem(
                                            value: 'queue',
                                            child: Text('Add to Queue'),
                                          ),
                                          PopupMenuItem(
                                            value: 'playlist',
                                            child: Text('Add to Playlist'),
                                          ),
                                          PopupMenuItem(
                                            value: 'remove',
                                            child: Text('Hapus dari Library'),
                                          ),
                                        ]
                                      : const [
                                          PopupMenuItem(
                                            value: 'locate',
                                            child: Text('Locate ulang'),
                                          ),
                                          PopupMenuItem(
                                            value: 'remove',
                                            child: Text('Hapus dari Library'),
                                          ),
                                        ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          _buildNowPlayingCard(),
        ],
      ),
    );
  }

  // ==================== TAB 2: PLAYLISTS ====================
  Widget _buildPlaylistsTab({required bool isDesktop}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 14,
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 12,
      ),
      child: Column(
        children: [
          Expanded(
            child: PlaylistsView(
              playlists: _playlists,
              allTracks: _allKnownTracks,
              currentTrackId: _currentTrack?.id,
              isDesktop: isDesktop,
              onCreatePlaylist: (name) => _createPlaylist(name),
              onRenamePlaylist: _renamePlaylist,
              onDeletePlaylist: _deletePlaylist,
              onAddTracksToPlaylist: _addTracksToPlaylist,
              onRemoveTrackFromPlaylist: _removeTrackFromPlaylist,
              onReorderPlaylistTrack: _reorderPlaylistTrack,
              onPlayTrack: (track, queue) =>
                  _playTrack(track, queue, resetShuffleCycle: true),
              onShufflePlaylist: _shuffleTracks,
              onLocateTrack: _locateTrack,
              onRemoveTrackFromLibrary: _removeTrackFromLibrary,
            ),
          ),
          const SizedBox(height: 12),
          _buildNowPlayingCard(),
        ],
      ),
    );
  }

  // ==================== TAB 3: SOURCES (PUSAT AGGREGATOR) ====================
  Widget _buildSourcesTab({required bool isDesktop}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 14,
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Music Sources',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Aktifkan atau nonaktifkan sumber musik yang ingin digabungkan ke beranda Noven.',
            style: TextStyle(color: NovenColors.silver.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: ListView.separated(
              itemCount: _sources.length,
              separatorBuilder: (_, _) => const SizedBox(height: 14),
              itemBuilder: (context, index) {
                final source = _sources[index];
                final isLocal = source.id == 'local';

                return Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: NovenColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: source.isEnabled
                          ? NovenColors.accentLight.withValues(alpha: 0.45)
                          : Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isLocal
                                ? Icons.folder_special_rounded
                                : Icons.cloud_queue_rounded,
                            color: source.isEnabled
                                ? NovenColors.accentLight
                                : NovenColors.silver.withValues(alpha: 0.45),
                            size: 28,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  source.name,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                                Text(
                                  source.description,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: NovenColors.silver.withValues(
                                      alpha: 0.75,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: source.isEnabled,
                            activeTrackColor: NovenColors.accent,
                            onChanged: (val) async {
                              source.isEnabled = val;
                              await _refreshSources();
                              await _saveStateNow(userAction: true);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: isLocal
                            ? [
                                OutlinedButton.icon(
                                  onPressed: _importFolder,
                                  icon: const Icon(
                                    Icons.folder_open_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Import Folder'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _importFiles,
                                  icon: const Icon(
                                    Icons.audio_file_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Tambah File'),
                                ),
                                if (_localSource.watchedFolders.isNotEmpty ||
                                    _localTracks.isNotEmpty)
                                  OutlinedButton.icon(
                                    onPressed: _rescanLocalFolders,
                                    icon: const Icon(
                                      Icons.refresh_rounded,
                                      size: 18,
                                    ),
                                    label: const Text('Rescan'),
                                  ),
                              ]
                            : [
                                FilledButton.tonalIcon(
                                  onPressed: _showAddUrlDialog,
                                  icon: const Icon(
                                    Icons.link_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Tambah URL Lagu'),
                                ),
                              ],
                      ),
                      if (isLocal &&
                          (_localSource.watchedFolders.isNotEmpty ||
                              _localTracks.isNotEmpty)) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final folder in _localSource.watchedFolders)
                              Tooltip(
                                message: folder,
                                child: InputChip(
                                  backgroundColor: NovenColors.bg,
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                  avatar: const Icon(
                                    Icons.folder_rounded,
                                    size: 15,
                                    color: NovenColors.accentLight,
                                  ),
                                  label: Text(
                                    _folderDisplayName(folder),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                  deleteIconColor: NovenColors.silver,
                                  onDeleted: () => _removeLocalFolder(folder),
                                ),
                              ),
                            if (_localTracks.isNotEmpty)
                              Chip(
                                backgroundColor: NovenColors.bg,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                                avatar: const Icon(
                                  Icons.storage_rounded,
                                  size: 15,
                                  color: NovenColors.silver,
                                ),
                                label: Text(
                                  () {
                                    final missingCount = _localTracks
                                        .where((t) => !t.isAvailable)
                                        .length;
                                    return missingCount > 0
                                        ? '${_localTracks.length} lagu di DB ($missingCount tidak tersedia)'
                                        : '${_localTracks.length} lagu tersimpan di DB';
                                  }(),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: NovenColors.silver,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (!isLocal &&
                          _onlineSource.customStreams.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final entry in _onlineSource.customStreams)
                              Tooltip(
                                message: entry.url,
                                child: InputChip(
                                  backgroundColor: NovenColors.bg,
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                  avatar: const Icon(
                                    Icons.link_rounded,
                                    size: 15,
                                    color: NovenColors.accentLight,
                                  ),
                                  label: Text(
                                    entry.title,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                  deleteIconColor: NovenColors.silver,
                                  onDeleted: () => _removeCustomUrl(entry.url),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          _buildNowPlayingCard(),
        ],
      ),
    );
  }
}

class _AddUrlDialog extends StatefulWidget {
  const _AddUrlDialog();

  @override
  State<_AddUrlDialog> createState() => _AddUrlDialogState();
}

class _AddUrlDialogState extends State<_AddUrlDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _artistCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop((
      title: _titleCtrl.text,
      artist: _artistCtrl.text,
      url: _urlCtrl.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NovenColors.surface,
      title: const Text('Tambah URL Lagu Online'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(labelText: 'Judul Lagu'),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _artistCtrl,
            decoration: const InputDecoration(labelText: 'Artis'),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'URL Audio (.mp3 / .ogg / .flac)',
              hintText: 'https://...',
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Tambah'),
        ),
      ],
    );
  }
}
