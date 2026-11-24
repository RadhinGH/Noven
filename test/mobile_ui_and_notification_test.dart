import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noven/controllers/library_controller.dart';
import 'package:noven/models/track.dart';
import 'package:noven/services/android_media_service.dart';
import 'package:noven/services/audio_engine.dart';
import 'package:noven/services/cover_cache_service.dart';
import 'package:noven/services/library_database.dart';
import 'package:noven/services/lyrics_service.dart';
import 'package:noven/services/storage_service.dart';
import 'package:noven/sources/local_source.dart';
import 'package:noven/ui/widgets/lyrics_panel.dart';
import 'package:noven/ui/widgets/queue_panel.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MockPlaybackBackend implements PlaybackBackend {
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
  void applyAudioSettings({required double volume, required bool isMuted}) {
    this.volume = volume;
    this.isMuted = isMuted;
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> playTrack(Track track, {Duration? startPosition}) async {
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
  }

  @override
  void toggleMute() {
    isMuted = !isMuted;
  }

  @override
  void togglePause() {
    if (!hasLoadedSource) return;
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

Track _sampleTrack(int index, {String? lyrics}) {
  return Track(
    id: 'local_t_$index',
    title: 'Song $index',
    artist: 'Artist $index',
    album: 'Album $index',
    sourceType: TrackSourceType.local,
    pathOrUrl: '/storage/emulated/0/Music/song_$index.mp3',
    duration: const Duration(minutes: 3),
    lyrics: lyrics,
  );
}

Future<void> _sendNativeMediaAction(
  String action, {
  int? positionMs,
}) async {
  const codec = StandardMethodCodec();
  final payload = <String, Object?>{'action': action};
  if (positionMs != null) {
    payload['positionMs'] = positionMs;
  }
  final byteData = codec.encodeMethodCall(
    MethodCall('onMediaAction', payload),
  );
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    AndroidMediaService.channelName,
    byteData,
    (_) {},
  );
}

void main() {
  late Directory tempDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('noven_mobile_ui_test_');
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

  testWidgets(
      'LyricsPanel synced auto-scroll only scrolls inner list without jumping outer ScrollView',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final outerController = ScrollController();
    final positionNotifier = ValueNotifier(Duration.zero);
    addTearDown(outerController.dispose);
    addTearDown(positionNotifier.dispose);

    final lrc = List.generate(
      20,
      (i) => '[00:${(i + 1).toString().padLeft(2, '0')}.00] Lyric line number ${i + 1}',
    ).join('\n');
    final track = _sampleTrack(1, lyrics: lrc);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: outerController,
            child: Column(
              children: [
                const SizedBox(height: 450),
                SizedBox(
                  height: 220,
                  child: LyricsPanel(
                    track: track,
                    positionListenable: positionNotifier,
                    onSeek: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(outerController.offset, 0.0);

    // Lompat maju beberapa baris lirik
    positionNotifier.value = const Duration(seconds: 2);
    await tester.pump();
    await tester.pumpAndSettle();

    positionNotifier.value = const Duration(seconds: 15);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(outerController.offset, 0.0);
    final innerScroll = tester.widget<SingleChildScrollView>(
      find
          .descendant(
            of: find.byType(LyricsPanel),
            matching: find.byType(SingleChildScrollView),
          )
          .first,
    );
    expect(innerScroll.controller, isNotNull);
    expect(innerScroll.controller!.offset, greaterThan(0.0));
  });

  testWidgets(
      'QueuePanel(maxListHeight: 220) stays compact with 1 song, lets outer view scroll, and caps at 6 songs',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final outerController = ScrollController();
    addTearDown(outerController.dispose);

    final oneTrack = [_sampleTrack(1)];

    Widget buildHarness(List<Track> queue) {
      return MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: outerController,
            child: Column(
              children: [
                QueuePanel(
                  playQueue: queue,
                  allTracks: queue,
                  currentTrackId: queue.first.id,
                  maxListHeight: 220,
                  onPlayFromQueue: (_) {},
                  onPlayFromAllTracks: (_, _) {},
                  onReorderQueue: (_, _) {},
                  onRemoveFromQueue: (_) {},
                  onClearQueue: () {},
                  onPlayNext: (_) {},
                  onAddToQueue: (_) {},
                  onAddToPlaylist: (_) {},
                ),
                const SizedBox(height: 800),
              ],
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildHarness(oneTrack));
    await tester.pumpAndSettle();

    final oneSongHeight = tester.getSize(find.byType(QueuePanel)).height;
    expect(oneSongHeight, lessThan(180.0));

    // Drag vertikal langsung di item Queue 1 lagu harus bisa menggeser outer scroll view
    await tester.drag(find.text('Song 1'), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(outerController.offset, greaterThan(0.0));

    // Dengan 6 lagu, tinggi QueuePanel dibatasi (maxListHeight 220 + header <= 290)
    outerController.jumpTo(0.0);
    final sixTracks = List.generate(6, (i) => _sampleTrack(i + 1));
    await tester.pumpWidget(buildHarness(sixTracks));
    await tester.pumpAndSettle();

    final sixSongHeight = tester.getSize(find.byType(QueuePanel)).height;
    expect(sixSongHeight, lessThanOrEqualTo(290.0));
    expect(sixSongHeight, greaterThan(oneSongHeight));
  });

  test(
      'AndroidMediaService + LibraryController sync notification state and handle native media actions',
      () async {
    const channel = MethodChannel(AndroidMediaService.channelName);
    final updates = <Map<String, dynamic>>[];
    int clearCalls = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'scanMediaStoreAudio':
          return [
            {
              'path': '/storage/emulated/0/Music/one.mp3',
              'title': 'Track One',
              'artist': 'Artist One',
              'album': 'Album One',
              'durationMs': 180000,
              'sizeBytes': 3 * 1024 * 1024,
            },
            {
              'path': '/storage/emulated/0/Music/two.mp3',
              'title': 'Track Two',
              'artist': 'Artist Two',
              'album': 'Album Two',
              'durationMs': 210000,
              'sizeBytes': 4 * 1024 * 1024,
            },
          ];
        case 'updateMediaNotification':
          final raw = Map<Object?, Object?>.from(call.arguments as Map);
          updates.add(raw.map((k, v) => MapEntry(k.toString(), v)));
          return true;
        case 'clearMediaNotification':
          clearCalls++;
          return true;
        default:
          return null;
      }
    });

    final androidMedia = AndroidMediaService(
      channel: channel,
      isAndroidOverride: true,
    );
    final playback = _MockPlaybackBackend();
    final db = LibraryDatabase(
      dbPathProvider: () async => p.join(tempDir.path, 'notif_sync.db'),
    );
    final coverCache = CoverCacheService(
      directoryProvider: () async => tempDir,
    );
    final storage = StorageService(directoryProvider: () async => tempDir);
    final source = LocalMusicSource(db: db, coverCache: coverCache);

    final controller = LibraryController(
      playback: playback,
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
    await controller.scanAndroidDeviceAudio();

    final tracks = controller.localTracks;
    expect(tracks.length, 2);
    final track1 = tracks[0];
    final track2 = tracks[1];

    // Play -> update notification isPlaying = true
    await controller.playTrack(track1, tracks);
    await pumpEventQueue();
    expect(updates, isNotEmpty);
    expect(updates.last['title'], 'Track One');
    expect(updates.last['isPlaying'], isTrue);

    // Pause -> isPlaying = false
    controller.togglePlayPause();
    await pumpEventQueue();
    expect(updates.last['isPlaying'], isFalse);

    // Native action: play -> resume
    await _sendNativeMediaAction('play');
    await pumpEventQueue();
    expect(playback.isPlaying, isTrue);
    expect(updates.last['isPlaying'], isTrue);

    // Native action: pause -> pause
    await _sendNativeMediaAction('pause');
    await pumpEventQueue();
    expect(playback.isPlaying, isFalse);
    expect(updates.last['isPlaying'], isFalse);

    // Native action: next -> advances to track 2
    await _sendNativeMediaAction('next');
    await pumpEventQueue();
    expect(controller.currentTrack?.id, track2.id);
    expect(updates.last['title'], 'Track Two');

    // Native action: previous -> returns to track 1
    await _sendNativeMediaAction('previous');
    await pumpEventQueue();
    expect(controller.currentTrack?.id, track1.id);
    expect(updates.last['title'], 'Track One');

    // Seek -> updates notification positionMs
    controller.seekToMs(45000);
    await pumpEventQueue();
    expect(updates.last['positionMs'], 45000);

    // Native action: seek -> updates playback position & notification
    await _sendNativeMediaAction('seek', positionMs: 60000);
    await pumpEventQueue();
    expect(playback.position, const Duration(seconds: 60));
    expect(updates.last['positionMs'], 60000);

    // Edit metadata -> updates notification title/album
    await controller.editTrackMetadata(
      track1.id,
      title: 'Track One (Live)',
      artist: 'Artist One',
      album: 'Live Session',
    );
    await pumpEventQueue();
    expect(updates.last['title'], 'Track One (Live)');
    expect(updates.last['album'], 'Live Session');

    // Native action: stop -> pauses while keeping currentTrack & clears notification
    final clearsBeforeStop = clearCalls;
    final updatesBeforeStop = updates.length;
    await _sendNativeMediaAction('stop');
    await pumpEventQueue();
    expect(playback.isPlaying, isFalse);
    expect(controller.currentTrack?.id, track1.id);
    expect(clearCalls, greaterThan(clearsBeforeStop));
    expect(updates.length, updatesBeforeStop);

    // Resume then remove track (when paused and current) -> stop & clearNotification
    await controller.playTrack(track1, [track1]);
    await pumpEventQueue();
    controller.togglePlayPause();
    await pumpEventQueue();
    final clearsBeforeRemove = clearCalls;
    await controller.removeTracksFromLibrary([track1.id]);
    await pumpEventQueue();
    expect(controller.currentTrack, isNull);
    expect(clearCalls, greaterThan(clearsBeforeRemove));

    controller.dispose();
  });
}
