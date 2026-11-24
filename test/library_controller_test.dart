import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noven/controllers/library_controller.dart';
import 'package:noven/models/track.dart';
import 'package:noven/services/audio_engine.dart';
import 'package:noven/services/cover_cache_service.dart';
import 'package:noven/services/library_database.dart';
import 'package:noven/services/lyrics_service.dart';
import 'package:noven/services/storage_service.dart';
import 'package:noven/sources/local_source.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakePlaybackBackend implements PlaybackBackend {
  @override
  final ValueNotifier<Float32List> fftNotifier = ValueNotifier(Float32List(0));
  @override
  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);

  @override
  bool isPlaying = false;
  @override
  bool isMuted = false;
  @override
  double volume = 0.6;
  @override
  Duration duration = Duration.zero;

  @override
  Duration get position => positionNotifier.value;
  @override
  bool hasLoadedSource = false;

  @override
  VoidCallback? onStateChanged;
  @override
  VoidCallback? onTrackComplete;

  final List<String> playedTrackIds = [];
  int stopCalls = 0;

  @override
  void applyAudioSettings({required double volume, required bool isMuted}) {
    this.volume = volume;
    this.isMuted = isMuted;
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> playTrack(Track track, {Duration? startPosition}) async {
    playedTrackIds.add(track.id);
    hasLoadedSource = true;
    isPlaying = true;
    duration = track.duration ?? const Duration(minutes: 3);
    positionNotifier.value = startPosition ?? Duration.zero;
    onStateChanged?.call();
  }

  @override
  Future<bool> replayCurrent() async {
    if (!hasLoadedSource) return false;
    isPlaying = true;
    positionNotifier.value = Duration.zero;
    onStateChanged?.call();
    return true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    hasLoadedSource = false;
    isPlaying = false;
    duration = Duration.zero;
    positionNotifier.value = Duration.zero;
    onStateChanged?.call();
  }

  @override
  void resetPosition() {
    positionNotifier.value = Duration.zero;
  }

  @override
  void setPreparedTrackState({
    required Duration duration,
    required Duration position,
  }) {
    this.duration = duration;
    positionNotifier.value = position;
  }

  @override
  void seek(Duration target) {
    positionNotifier.value = target;
  }

  @override
  void setVolume(double value) {
    volume = value;
    isMuted = value == 0.0;
  }

  @override
  void toggleMute() {
    isMuted = !isMuted;
  }

  @override
  void togglePause() {
    isPlaying = !isPlaying;
    onStateChanged?.call();
  }

  @override
  Future<void> dispose() async {
    fftNotifier.dispose();
    positionNotifier.dispose();
  }
}

class _NoopLyricsService extends LyricsService {
  @override
  Future<String?> fetchLyrics(Track track, {bool forceRefresh = false}) async {
    return null;
  }
}

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('noven_controller_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<
      ({
        LibraryController controller,
        FakePlaybackBackend playback,
        LibraryDatabase db,
        StorageService storage,
      })> createInitializedController({
    List<String> Function()? pickFilesSync,
  }) async {
    final db = LibraryDatabase(
      dbPathProvider: () async => p.join(tempDir.path, 'noven_library.db'),
    );
    final coverCache = CoverCacheService(directoryProvider: () async => tempDir);
    final storage = StorageService(directoryProvider: () async => tempDir);
    final playback = FakePlaybackBackend();
    final localSource = LocalMusicSource(
      db: db,
      coverCache: coverCache,
      pickFilesOverride:
          pickFilesSync == null ? null : () async => pickFilesSync(),
    );

    final controller = LibraryController(
      playback: playback,
      storage: storage,
      libraryDb: db,
      coverCache: coverCache,
      localSource: localSource,
      lyricsService: _NoopLyricsService(),
      playbackPersistInterval: const Duration(hours: 1),
      saveDebounceDuration: const Duration(milliseconds: 10),
    );
    await controller.initialize(runBackgroundRescan: false);
    return (
      controller: controller,
      playback: playback,
      db: db,
      storage: storage,
    );
  }

  Future<File> createDummyAudio(String relativePath, [List<int>? bytes]) async {
    final file = File(p.join(tempDir.path, relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes ?? [0x49, 0x44, 0x33, 0x03, 0x00]);
    return file;
  }

  group('LibraryController Add & Duplicate Detection', () {
    test('importDroppedPaths mendeteksi duplikat file/folder dan format invalid',
        () async {
      final setup = await createInitializedController();
      final controller = setup.controller;

      final f1 = await createDummyAudio('drop/alpha.mp3');
      final f2 = await createDummyAudio('drop/sub/beta.flac');
      final bad = await createDummyAudio('drop/readme.txt', [1, 2, 3]);
      final solo = await createDummyAudio('solo.ogg');

      final firstDrop = await controller.importDroppedPaths([
        p.join(tempDir.path, 'drop'),
        solo.path,
        bad.path,
      ]);

      expect(firstDrop.added, 3);
      expect(firstDrop.duplicates, 0);
      expect(firstDrop.unsupported, 1);
      expect(controller.localTracks.length, 3);

      // Drop ulang folder + file sama -> terdeteksi sebagai duplikat
      final secondDrop = await controller.importDroppedPaths([
        f1.path,
        f2.path,
        solo.path,
        solo.path,
      ]);
      expect(secondDrop.added, 0);
      expect(secondDrop.duplicates, 4);
      expect(controller.localTracks.length, 3);

      // URL stream duplikat ditolak
      final ok1 = await controller.addCustomUrl(
        title: 'Stream 1',
        artist: 'Artist',
        url: 'https://example.com/live.mp3',
      );
      final dupUrl = await controller.addCustomUrl(
        title: 'Stream 1 Copy',
        artist: 'Artist',
        url: 'https://example.com/live.mp3',
      );
      expect(ok1, isTrue);
      expect(dupUrl, isFalse);

      controller.dispose();
    });
  });

  group('LibraryController Remove, Undo & Dampak Queue/Playlist/History', () {
    test(
        'remove multi-select hapus dari DB/queue/playlist/history tanpa hapus file disk, dan undo memulihkannya',
        () async {
      final setup = await createInitializedController();
      final controller = setup.controller;

      final f1 = await createDummyAudio('a.mp3');
      final f2 = await createDummyAudio('b.flac');
      final f3 = await createDummyAudio('c.wav');

      await controller.importDroppedPaths([f1.path, f2.path, f3.path]);
      final t1 = controller.localTracks.firstWhere((t) => t.pathOrUrl == f1.path);
      final t2 = controller.localTracks.firstWhere((t) => t.pathOrUrl == f2.path);
      final t3 = controller.localTracks.firstWhere((t) => t.pathOrUrl == f3.path);

      controller.createPlaylist('Mix', initialTrackIds: [t1.id, t2.id, t3.id]);
      final playlistId = controller.playlists.single.id;

      // Putar t1 lalu t2 agar t1 masuk playHistory dan [t1, t2, t3] masuk playQueue
      await controller.playTrack(t1, [t1, t2, t3]);
      await controller.playTrack(t2, [t1, t2, t3]);
      expect(controller.playHistory.map((t) => t.id), [t1.id]);

      // Multi-select t1 dan t3 lalu hapus dari library
      controller.enterSelectionMode(t1.id);
      controller.toggleTrackSelection(t3.id);
      expect(controller.selectedTrackIds, {t1.id, t3.id});

      final removeRes = await controller.removeTracksFromLibrary(
        controller.selectedTrackIds.toList(),
      );
      expect(removeRes?.count, 2);
      expect(controller.hasPendingUndo, isTrue);
      expect(controller.isSelectionMode, isFalse);

      // File asli di disk TIDAK boleh terhapus
      expect(f1.existsSync(), isTrue);
      expect(f2.existsSync(), isTrue);
      expect(f3.existsSync(), isTrue);

      // Library, queue, playlist, dan history terbersihkan
      expect(controller.localTracks.map((t) => t.id), [t2.id]);
      expect(controller.playQueue.map((t) => t.id), [t2.id]);
      expect(controller.playlists.single.id, playlistId);
      expect(controller.playlists.single.trackIds, [t2.id]);
      expect(controller.playHistory, isEmpty);

      // Undo -> mengembalikan track ke DB serta posisi semula di playlist/queue/history
      final undone = await controller.undoLastRemove();
      expect(undone, isTrue);
      expect(controller.hasPendingUndo, isFalse);
      expect(controller.localTracks.length, 3);
      expect(controller.playQueue.map((t) => t.id), [t1.id, t2.id, t3.id]);
      expect(controller.playlists.single.trackIds, [t1.id, t2.id, t3.id]);
      expect(controller.playHistory.map((t) => t.id), [t1.id]);

      controller.dispose();
    });

    test(
        'hapus lagu yang sedang diputar lanjut ke lagu berikutnya; kalau queue habis, stop dengan rapi',
        () async {
      final setup = await createInitializedController();
      final controller = setup.controller;
      final playback = setup.playback;

      final f1 = await createDummyAudio('one.mp3');
      final f2 = await createDummyAudio('two.mp3');
      await controller.importDroppedPaths([f1.path, f2.path]);

      final t1 = controller.localTracks.firstWhere((t) => t.pathOrUrl == f1.path);
      final t2 = controller.localTracks.firstWhere((t) => t.pathOrUrl == f2.path);

      await controller.playTrack(t1, [t1, t2]);
      expect(controller.currentTrack?.id, t1.id);
      expect(playback.isPlaying, isTrue);

      // Hapus t1 saat sedang diputar -> harus otomatis lanjut ke t2
      await controller.removeTracksFromLibrary([t1.id]);
      expect(controller.currentTrack?.id, t2.id);
      expect(playback.playedTrackIds.last, t2.id);
      expect(playback.isPlaying, isTrue);

      // Hapus t2 (lagu terakhir) -> harus stop dengan rapi & currentTrack null
      await controller.removeTracksFromLibrary([t2.id]);
      expect(controller.currentTrack, isNull);
      expect(playback.stopCalls, 1);
      expect(playback.isPlaying, isFalse);
      expect(controller.playQueue, isEmpty);

      // Undo lagu terakhir -> siap dilanjutkan kembali
      await controller.undoLastRemove();
      expect(controller.currentTrack?.id, t2.id);
      expect(controller.localTracks.map((t) => t.id), [t2.id]);

      controller.dispose();
    });
  });

  group('LibraryController Edit Metadata, Favorite & DB v2 Migration', () {
    test('edit metadata & favorite tersimpan di DB, tidak mengubah file asli, dan bertahan saat rescan',
        () async {
      final setup = await createInitializedController();
      final controller = setup.controller;

      final originalBytes = [0x49, 0x44, 0x33, 0x03, 0x00, 0x11, 0x22];
      final audioFile = await createDummyAudio('custom.mp3', originalBytes);
      await controller.importDroppedPaths([audioFile.path]);

      final track = controller.localTracks.single;
      final edited = await controller.editTrackMetadata(
        track.id,
        title: 'Judul Kustom',
        artist: 'Artis Kustom',
        album: 'Album Kustom',
      );
      expect(edited?.title, 'Judul Kustom');
      expect(edited?.hasCustomMetadata, isTrue);

      final favLocal = await controller.toggleFavorite(edited!);
      expect(favLocal?.isFavorite, isTrue);

      // Toggle favorite untuk lagu stream juga persisten
      final streamTrack = controller.allTracks.firstWhere(
        (t) => t.sourceType == TrackSourceType.stream,
      );
      final favStream = await controller.toggleFavorite(streamTrack);
      expect(favStream?.isFavorite, isTrue);

      // File audio asli di disk tidak berubah sama sekali
      expect(await audioFile.readAsBytes(), originalBytes);

      // Rescan tidak menimpa custom metadata maupun favorite
      await controller.rescanLocalFolders();
      final afterRescan = controller.localTracks.single;
      expect(afterRescan.title, 'Judul Kustom');
      expect(afterRescan.artist, 'Artis Kustom');
      expect(afterRescan.album, 'Album Kustom');
      expect(afterRescan.isFavorite, isTrue);

      await controller.saveNow(userAction: true);
      controller.dispose();

      // Reopen controller dari DB + JSON yang sama
      final reopened = await createInitializedController();
      final reloadedLocal = reopened.controller.localTracks.single;
      expect(reloadedLocal.title, 'Judul Kustom');
      expect(reloadedLocal.artist, 'Artis Kustom');
      expect(reloadedLocal.album, 'Album Kustom');
      expect(reloadedLocal.isFavorite, isTrue);

      final reloadedStream = reopened.controller.allTracks.firstWhere(
        (t) => t.id == streamTrack.id,
      );
      expect(reloadedStream.isFavorite, isTrue);

      reopened.controller.dispose();
    });

    test('upgrade SQLite DB v1 ke v2 menjaga lagu lama tetap utuh', () async {
      final dbPath = p.join(tempDir.path, 'upgrade_v1_to_v2.db');
      final v1Db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
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
                lyrics TEXT
              )
            ''');
            await db.execute('''
              CREATE TABLE watched_folders (
                path TEXT PRIMARY KEY,
                added_at INTEGER NOT NULL
              )
            ''');
          },
        ),
      );
      await v1Db.insert('tracks', {
        'id': 'legacy_id',
        'path_or_uri': 'C:/Music/old.mp3',
        'title': 'Old Song',
        'artist': 'Old Artist',
        'album': 'Old Album',
        'duration_ms': 123000,
        'cover_path': null,
        'added_at': 1700000000000,
        'is_available': 1,
        'source_type': 'local',
        'lyrics': null,
      });
      await v1Db.close();

      final upgradedDb = LibraryDatabase(dbPathProvider: () async => dbPath);
      final tracks = await upgradedDb.getAllTracks();
      expect(tracks.length, 1);
      expect(tracks.single.id, 'legacy_id');
      expect(tracks.single.title, 'Old Song');
      expect(tracks.single.isFavorite, isFalse);
      expect(tracks.single.hasCustomMetadata, isFalse);

      await upgradedDb.close();
    });
  });
}
