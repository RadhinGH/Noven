import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noven/models/playlist.dart';
import 'package:noven/models/repeat_mode.dart';
import 'package:noven/models/track.dart';
import 'package:noven/services/cover_cache_service.dart';
import 'package:noven/services/library_database.dart';
import 'package:noven/services/persistence_guard.dart';
import 'package:noven/services/storage_service.dart';
import 'package:noven/sources/local_source.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('noven_persistence_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('StorageService atomic JSON, corrupt handling & schema migration', () {
    test('roundtrip serialisasi dan backup .bak saat save kedua', () async {
      final storage = StorageService(directoryProvider: () async => tempDir);

      final initialState = NovenSavedState(
        schemaVersion: NovenSavedState.currentSchemaVersion,
        legacyLibraryMigrated: true,
        localFolders: const ['C:/Music/Indie'],
        localFiles: const [],
        customStreams: const [
          CustomStreamEntry(
            title: 'Lofi Station',
            artist: 'Radio',
            url: 'https://example.com/stream.mp3',
          ),
        ],
        sourceEnabled: const {'local': true, 'online': false},
        volume: 0.42,
        isMuted: true,
        shuffle: true,
        repeatMode: PlaybackRepeatMode.one,
        playlists: [
          Playlist(
            id: 'pl_1',
            name: 'Night Drive',
            trackIds: const ['track_a', 'https://example.com/stream.mp3'],
            createdAt: DateTime.utc(2026, 1, 15, 20, 30),
          ),
        ],
        lastTrackId: 'track_a',
        lastPositionMs: 91234,
      );

      final savedFirst = await storage.save(initialState);
      expect(savedFirst, isTrue);

      final mainFile = File(p.join(tempDir.path, 'noven_data.json'));
      final bakFile = File(p.join(tempDir.path, 'noven_data.json.bak'));
      expect(mainFile.existsSync(), isTrue);
      expect(bakFile.existsSync(), isFalse);

      final loaded = await storage.loadWithStatus();
      expect(loaded.status, StorageLoadStatus.ok);
      expect(loaded.state.schemaVersion, NovenSavedState.currentSchemaVersion);
      expect(loaded.state.legacyLibraryMigrated, isTrue);
      expect(loaded.state.volume, closeTo(0.42, 0.0001));
      expect(loaded.state.isMuted, isTrue);
      expect(loaded.state.shuffle, isTrue);
      expect(loaded.state.repeatMode, PlaybackRepeatMode.one);
      expect(loaded.state.sourceEnabled, {'local': true, 'online': false});
      expect(loaded.state.customStreams.single.url,
          'https://example.com/stream.mp3');
      expect(loaded.state.playlists.single.name, 'Night Drive');
      expect(loaded.state.playlists.single.trackIds,
          ['track_a', 'https://example.com/stream.mp3']);
      expect(loaded.state.lastTrackId, 'track_a');
      expect(loaded.state.lastPositionMs, 91234);

      // Save kedua harus memindahkan snapshot lama ke .bak
      final updated = initialState.copyWith(volume: 0.85, lastPositionMs: 120000);
      await storage.save(updated);
      expect(bakFile.existsSync(), isTrue);

      final bakJson =
          jsonDecode(await bakFile.readAsString()) as Map<String, dynamic>;
      expect((bakJson['volume'] as num).toDouble(), closeTo(0.42, 0.0001));
      expect(bakJson['lastPositionMs'], 91234);
    });

    test('file korup tanpa backup di-rename ke .corrupt dan TIDAK ditimpa',
        () async {
      final storage = StorageService(directoryProvider: () async => tempDir);
      final mainFile = File(p.join(tempDir.path, 'noven_data.json'));
      const corruptPayload = '{corrupt json !!!';
      await mainFile.writeAsString(corruptPayload);

      final result = await storage.loadWithStatus();
      expect(result.status, StorageLoadStatus.corrupted);
      expect(storage.hasUnrecoveredCorruption, isTrue);
      expect(mainFile.existsSync(), isFalse);

      final corruptFile = File(p.join(tempDir.path, 'noven_data.json.corrupt'));
      expect(corruptFile.existsSync(), isTrue);
      expect(await corruptFile.readAsString(), corruptPayload);

      // Tidak boleh menimpa file utama dengan defaults sebelum aksi user
      final blockedSave = await storage.save(NovenSavedState.defaults);
      expect(blockedSave, isFalse);
      expect(mainFile.existsSync(), isFalse);
    });

    test('file korup dengan .bak valid memulihkan state dan menyimpan .corrupt',
        () async {
      final storage = StorageService(directoryProvider: () async => tempDir);
      final v1 = NovenSavedState.defaults.copyWith(
        volume: 0.77,
        lastTrackId: 'song_1',
        lastPositionMs: 45000,
      );
      await storage.save(v1);
      await storage.save(v1.copyWith(volume: 0.33));

      // Korupkan noven_data.json -> .bak masih menyimpan v1 (volume 0.77)
      final mainFile = File(p.join(tempDir.path, 'noven_data.json'));
      await mainFile.writeAsString('<<<broken>>>');

      final recovered = await storage.loadWithStatus();
      expect(recovered.status, StorageLoadStatus.recoveredFromBackup);
      expect(recovered.state.volume, closeTo(0.77, 0.0001));
      expect(recovered.state.lastTrackId, 'song_1');
      expect(recovered.state.lastPositionMs, 45000);
      expect(
        File(p.join(tempDir.path, 'noven_data.json.corrupt')).existsSync(),
        isTrue,
      );
    });
  });

  group('PersistenceGuard load-before-save & debounce', () {
    test('memblokir semua save sebelum markReady dan mendebounce setelahnya',
        () async {
      var saveCalls = 0;
      final guard = PersistenceGuard(
        debounceDuration: const Duration(milliseconds: 60),
        onSave: () async {
          saveCalls++;
        },
      );

      guard.scheduleSave();
      await guard.saveNow();
      expect(saveCalls, 0);
      expect(guard.blockedSaveAttempts, 2);

      // markReady tidak memutar ulang blokir lama
      guard.markReady();
      expect(saveCalls, 0);

      // 3 scheduleSave cepat -> 1 call
      guard.scheduleSave();
      guard.scheduleSave();
      guard.scheduleSave();
      expect(guard.hasPendingSave, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(saveCalls, 1);
      expect(guard.hasPendingSave, isFalse);

      // flushIfPending menulis langsung
      guard.scheduleSave();
      expect(guard.hasPendingSave, isTrue);
      await guard.flushIfPending();
      expect(saveCalls, 2);
      expect(guard.hasPendingSave, isFalse);

      guard.dispose();
    });
  });

  group('SQLite LibraryDatabase, disk cover cache & legacy migration', () {
    test('migrasi schema v1 + legacy localFiles/localFolders ke SQLite tanpa hilang',
        () async {
      final storage = StorageService(directoryProvider: () async => tempDir);
      final musicDir = Directory(p.join(tempDir.path, 'Music'));
      await musicDir.create();

      final existingFile = File(p.join(musicDir.path, 'demo_ok.mp3'));
      await existingFile.writeAsBytes([0x49, 0x44, 0x33, 0x03, 0x00]);
      final missingFilePath = p.join(tempDir.path, 'gone_track.mp3');

      final legacyJson = {
        'localFolders': [musicDir.path],
        'localFiles': [missingFilePath],
        'customStreams': <dynamic>[],
        'sourceEnabled': {'local': true, 'online': true},
        'volume': 0.55,
        'isMuted': false,
        'shuffle': true,
        'repeatMode': 'all',
        'playlists': [
          {
            'id': 'pl_legacy',
            'name': 'Favorites',
            'trackIds': [existingFile.path, missingFilePath],
            'createdAt': '2026-01-01T00:00:00.000Z',
          }
        ],
        'lastTrackId': existingFile.path,
        'lastPositionMs': 15000,
      };
      await File(p.join(tempDir.path, 'noven_data.json'))
          .writeAsString(jsonEncode(legacyJson));

      final loadResult = await storage.loadWithStatus();
      expect(loadResult.status, StorageLoadStatus.migrated);
      expect(loadResult.state.schemaVersion, 2);
      expect(loadResult.state.legacyLibraryMigrated, isFalse);

      final db = LibraryDatabase(
        dbPathProvider: () async => p.join(tempDir.path, 'noven_library.db'),
      );
      final coverCache = CoverCacheService(
        directoryProvider: () async => tempDir,
      );
      final source = LocalMusicSource(db: db, coverCache: coverCache);

      final migratedCount = await source.migrateLegacyData(
        folders: loadResult.state.localFolders,
        files: loadResult.state.localFiles,
      );
      expect(migratedCount, 2);
      expect(source.watchedFolders, contains(p.normalize(musicDir.path)));

      final tracks = await source.fetchTracks();
      expect(tracks.length, 2);

      final byId = {for (final t in tracks) t.id: t};
      expect(byId[existingFile.path]?.isAvailable, isTrue);
      // File yang hilang tetap tersimpan sebagai tidak tersedia, bukan dibuang
      expect(byId[missingFilePath]?.isAvailable, isFalse);

      // Playlist lama tetap valid merujuk kedua trackId
      for (final id in loadResult.state.playlists.single.trackIds) {
        expect(byId.containsKey(id), isTrue);
      }

      await db.close();
    });

    test(
        'cover cache disk deduplikasi, DB reopen bertahan, missing & locate ulang jaga playlistId',
        () async {
      final dbPath = p.join(tempDir.path, 'noven_library.db');
      final coverCache = CoverCacheService(
        directoryProvider: () async => tempDir,
      );

      final pngBytes = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4,
      ]);
      final savedCover1 = await coverCache.saveCoverBytes(pngBytes);
      final savedCover2 = await coverCache.saveCoverBytes(pngBytes);
      expect(savedCover1, isNotNull);
      expect(savedCover1, equals(savedCover2));
      expect(savedCover1!.endsWith('.png'), isTrue);
      expect(File(savedCover1).existsSync(), isTrue);

      final audioFile = File(p.join(tempDir.path, 'song_one.flac'));
      await audioFile.writeAsBytes([0x66, 0x4C, 0x61, 0x43]);
      final originalId = audioFile.path;

      final db1 = LibraryDatabase(dbPathProvider: () async => dbPath);
      await db1.upsertTrack(
        Track(
          id: originalId,
          title: 'Starlight',
          artist: 'Noven',
          album: 'Violet',
          pathOrUrl: audioFile.path,
          sourceType: TrackSourceType.local,
          coverPath: savedCover1,
          duration: const Duration(minutes: 3, seconds: 42),
          addedAt: DateTime.utc(2026, 5, 1),
          isAvailable: true,
        ),
      );
      await db1.close();

      // Reopen DB (simulasi buka app lagi setelah tutup paksa)
      final db2 = LibraryDatabase(dbPathProvider: () async => dbPath);
      final source = LocalMusicSource(db: db2, coverCache: coverCache);
      await source.loadFromDatabase();

      var tracks = await source.fetchTracks();
      expect(tracks.length, 1);
      expect(tracks.single.id, originalId);
      expect(tracks.single.title, 'Starlight');
      expect(tracks.single.coverPath, savedCover1);
      expect(tracks.single.duration, const Duration(minutes: 3, seconds: 42));
      expect(tracks.single.isAvailable, isTrue);

      final playlist = Playlist(
        id: 'pl_main',
        name: 'Keep Valid',
        trackIds: [originalId],
        createdAt: DateTime.utc(2026, 5, 1),
      );

      // Hapus file audio -> background rescan tandai tidak tersedia, BUKAN hapus
      await audioFile.delete();
      final rescan = await source.rescanInBackground();
      expect(rescan.unavailable, 1);

      tracks = await source.fetchTracks();
      expect(tracks.length, 1);
      expect(tracks.single.id, originalId);
      expect(tracks.single.isAvailable, isFalse);

      // Locate ulang ke file baru -> id tetap sama sehingga playlist tetap valid
      final relocatedFile = File(p.join(tempDir.path, 'song_one_moved.flac'));
      await relocatedFile.writeAsBytes([0x66, 0x4C, 0x61, 0x43]);

      final relocated =
          await source.relocateTrackToPath(originalId, relocatedFile.path);
      expect(relocated, isNotNull);
      expect(relocated!.id, originalId);
      expect(relocated.pathOrUrl, relocatedFile.path);
      expect(relocated.isAvailable, isTrue);
      expect(playlist.trackIds.contains(relocated.id), isTrue);

      await db2.close();
    });
  });
}
