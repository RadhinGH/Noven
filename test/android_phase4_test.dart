import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart' show LoadMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:noven/controllers/library_controller.dart';
import 'package:noven/main.dart';
import 'package:noven/models/track.dart';
import 'package:noven/services/android_media_service.dart';
import 'package:noven/services/audio_engine.dart';
import 'package:noven/services/cover_cache_service.dart';
import 'package:noven/services/library_database.dart';
import 'package:noven/services/lyrics_service.dart';
import 'package:noven/services/storage_service.dart';
import 'package:noven/sources/local_source.dart';
import 'package:noven/ui/widgets/now_playing_card.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePlaybackBackend implements PlaybackBackend {
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

  @override
  void applyAudioSettings({required double volume, required bool isMuted}) {}
  @override
  Future<void> init() async {}
  @override
  Future<void> playTrack(Track track, {Duration? startPosition}) async {}
  @override
  Future<bool> replayCurrent() async => false;
  @override
  Future<void> stop() async {}
  @override
  void resetPosition() {}
  @override
  void setPreparedTrackState({
    required Duration duration,
    required Duration position,
  }) {}
  @override
  void seek(Duration target) {}
  @override
  void setVolume(double value) {}
  @override
  void toggleMute() {}
  @override
  void togglePause() {}
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
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('noven_android_p4_test_');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(AndroidMediaService.channelName),
      null,
    );
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('AudioEngine.selectLoadMode', () {
    test('Android memakai LoadMode.disk untuk FLAC/WAV/OGG/OPUS/M4A dan MP3 besar',
        () {
      expect(
        AudioEngine.selectLoadMode(
          isAndroid: true,
          pathOrUrl: '/storage/emulated/0/Music/lossless.flac',
          sourceType: TrackSourceType.local,
          fileSizeBytes: 35 * 1024 * 1024,
        ),
        LoadMode.disk,
      );
      expect(
        AudioEngine.selectLoadMode(
          isAndroid: true,
          pathOrUrl: '/storage/emulated/0/Music/song.wav',
          sourceType: TrackSourceType.local,
        ),
        LoadMode.disk,
      );
      expect(
        AudioEngine.selectLoadMode(
          isAndroid: true,
          pathOrUrl: '/storage/emulated/0/Music/podcast.mp3',
          sourceType: TrackSourceType.local,
          fileSizeBytes: 15 * 1024 * 1024,
        ),
        LoadMode.disk,
      );
      // MP3 ukuran normal (< 12 MB) tetap pakai memory agar seek halus
      expect(
        AudioEngine.selectLoadMode(
          isAndroid: true,
          pathOrUrl: '/storage/emulated/0/Music/track.mp3',
          sourceType: TrackSourceType.local,
          fileSizeBytes: 4 * 1024 * 1024,
        ),
        LoadMode.memory,
      );
    });

    test('Desktop dan stream query string dipetakan dengan benar', () {
      expect(
        AudioEngine.selectLoadMode(
          isAndroid: false,
          pathOrUrl: r'C:\Music\album.flac',
          sourceType: TrackSourceType.local,
          fileSizeBytes: 30 * 1024 * 1024,
        ),
        LoadMode.memory,
      );
      expect(
        AudioEngine.selectLoadMode(
          isAndroid: false,
          pathOrUrl: r'C:\Music\concert.wav',
          sourceType: TrackSourceType.local,
          fileSizeBytes: 45 * 1024 * 1024,
        ),
        LoadMode.disk,
      );
      expect(
        AudioEngine.selectLoadMode(
          isAndroid: true,
          pathOrUrl: 'https://cdn.example.com/audio.flac?token=123',
          sourceType: TrackSourceType.stream,
        ),
        LoadMode.disk,
      );
      expect(
        AudioEngine.selectLoadMode(
          isAndroid: true,
          pathOrUrl: 'https://cdn.example.com/audio.mp3?token=123',
          sourceType: TrackSourceType.stream,
        ),
        LoadMode.memory,
      );
    });
  });

  group('AndroidMediaService permission flow & MediaStore scan', () {
    test('status permission, permanentlyDenied -> openAppSettings, dan graceful fallback',
        () async {
      const channel = MethodChannel(AndroidMediaService.channelName);
      var audioStatus = 'denied';
      var notifStatus = 'denied';
      var openedSettings = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'checkAudioPermission':
            return audioStatus;
          case 'requestAudioPermission':
            audioStatus = 'permanentlyDenied';
            return audioStatus;
          case 'checkNotificationPermission':
            return notifStatus;
          case 'requestNotificationPermission':
            notifStatus = 'granted';
            return notifStatus;
          case 'openAppSettings':
            openedSettings = true;
            return true;
          default:
            return null;
        }
      });

      final service = AndroidMediaService(
        channel: channel,
        isAndroidOverride: true,
      );

      expect(
        await service.checkAudioPermission(),
        AndroidPermissionStatus.denied,
      );
      expect(
        await service.requestAudioPermission(),
        AndroidPermissionStatus.permanentlyDenied,
      );
      expect(
        await service.checkNotificationPermission(),
        AndroidPermissionStatus.denied,
      );
      expect(
        await service.requestNotificationPermission(),
        AndroidPermissionStatus.granted,
      );
      expect(await service.openAppSettings(), isTrue);
      expect(openedSettings, isTrue);

      // Saat MissingPluginException (tanpa implementasi native) tidak crash
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(
        await service.checkAudioPermission(),
        AndroidPermissionStatus.unsupported,
      );
      expect(await service.scanDeviceAudio(), isEmpty);
    });

    test('scanAndroidDeviceAudio masuk SQLite, deteksi duplikat, dan jaga edit/favorit',
        () async {
      const channel = MethodChannel(AndroidMediaService.channelName);
      final coverFile = File(p.join(tempDir.path, 'covers', 'ms_album_1.jpg'));
      await coverFile.parent.create(recursive: true);
      await coverFile.writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0]);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'scanMediaStoreAudio') {
          return [
            {
              'path': '/storage/emulated/0/Music/violet.flac',
              'contentUri': 'content://media/external/audio/media/42',
              'title': 'Violet',
              'artist': 'Noven',
              'album': 'Purple',
              'durationMs': 245000,
              'sizeBytes': 28 * 1024 * 1024,
              'coverPath': coverFile.path,
              'addedAtMs': 1700000000000,
            },
          ];
        }
        return null;
      });

      final androidMedia = AndroidMediaService(
        channel: channel,
        isAndroidOverride: true,
      );
      final db = LibraryDatabase(
        dbPathProvider: () async => p.join(tempDir.path, 'android_lib.db'),
      );
      final coverCache = CoverCacheService(
        directoryProvider: () async => tempDir,
      );
      final storage = StorageService(directoryProvider: () async => tempDir);
      final source = LocalMusicSource(db: db, coverCache: coverCache);

      final controller = LibraryController(
        playback: _FakePlaybackBackend(),
        storage: storage,
        libraryDb: db,
        coverCache: coverCache,
        localSource: source,
        lyricsService: _NoopLyricsService(),
        androidMedia: androidMedia,
        playbackPersistInterval: const Duration(hours: 1),
        saveDebounceDuration: const Duration(milliseconds: 10),
      );
      await controller.initialize(runBackgroundRescan: false);

      final firstScan = await controller.scanAndroidDeviceAudio();
      expect(firstScan.added, 1);
      expect(firstScan.duplicates, 0);
      expect(controller.localTracks.length, 1);
      expect(controller.localTracks.single.coverPath, coverFile.path);

      // Edit & favorit lagu hasil scan
      final scanned = controller.localTracks.single;
      await controller.editTrackMetadata(
        scanned.id,
        title: 'Violet (Remaster)',
        artist: 'Noven Custom',
        album: 'Purple',
      );
      await controller.toggleFavorite(controller.localTracks.single);

      // Scan ulang -> duplikat dihitung & edit kustom + favorit tetap bertahan
      final secondScan = await controller.scanAndroidDeviceAudio();
      expect(secondScan.added, 0);
      expect(secondScan.duplicates, 1);
      expect(controller.localTracks.single.title, 'Violet (Remaster)');
      expect(controller.localTracks.single.artist, 'Noven Custom');
      expect(controller.localTracks.single.isFavorite, isTrue);

      controller.dispose();
    });
  });

  group('Mobile UI layout (360dp), SafeArea, Back & 48dp touch targets', () {
    testWidgets(
        'renders all 4 tabs at 360x640 without overflow, >= 48dp buttons, SafeArea & Back',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const NovenApp());
      await tester.pumpAndSettle();

      expect(find.byType(SafeArea), findsWidgets);
      expect(find.byWidgetPredicate((w) => w is PopScope), findsOneWidget);
      expect(find.byType(NowPlayingCard), findsOneWidget);

      // Cek semua tombol kontrol utama NowPlayingCard memiliki ukuran sentuh >= 48dp
      for (final icon in [
        Icons.play_arrow_rounded,
        Icons.skip_previous_rounded,
        Icons.skip_next_rounded,
        Icons.shuffle_rounded,
        Icons.repeat_rounded,
        Icons.volume_up_rounded,
        Icons.playlist_play_rounded,
      ]) {
        final buttonFinder = find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(IconButton),
        );
        expect(buttonFinder, findsOneWidget);
        final size = tester.getSize(buttonFinder);
        expect(size.width, greaterThanOrEqualTo(48.0));
        expect(size.height, greaterThanOrEqualTo(48.0));
      }

      // Berpindah ke semua tab di 360dp tanpa overflow error
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      expect(find.text('Library'), findsWidgets);

      // Tombol Back sistem harus kembali dari Library ke Home tab
      final popHandled = await tester.binding.handlePopRoute();
      expect(popHandled, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Your Albums'), findsOneWidget);

      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      expect(find.text('Buat Playlist'), findsOneWidget);

      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      expect(find.text('Music Sources'), findsOneWidget);
    });
  });
}
