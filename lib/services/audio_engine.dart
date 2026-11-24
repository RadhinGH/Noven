import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'android_media_service.dart';

abstract class PlaybackBackend {
  ValueNotifier<Float32List> get fftNotifier;
  ValueNotifier<Duration> get positionNotifier;

  bool get isPlaying;
  bool get isMuted;
  double get volume;
  Duration get duration;
  Duration get position;
  bool get hasLoadedSource;

  VoidCallback? get onStateChanged;
  set onStateChanged(VoidCallback? value);

  VoidCallback? get onTrackComplete;
  set onTrackComplete(VoidCallback? value);

  void setPreparedTrackState({
    required Duration duration,
    required Duration position,
  });

  void applyAudioSettings({required double volume, required bool isMuted});
  Future<void> init();
  Future<void> playTrack(Track track, {Duration? startPosition});
  Future<bool> replayCurrent();
  Future<void> stop();
  void resetPosition();
  void togglePause();
  void seek(Duration target);
  void setVolume(double value);
  void toggleMute();
  Future<void> dispose();
}

class AudioEngine implements PlaybackBackend {
  /// Di Android, MP3 biasa (< 12 MB) tetap pakai [LoadMode.memory] agar seek
  /// slider responsif (sesuai catatan SoLoud), sedangkan file FLAC/WAV/OGG/M4A
  /// dan MP3 besar (>= 12 MB) streaming dari disk agar RAM aman di HP.
  static const int androidDiskModeMp3ThresholdBytes = 12 * 1024 * 1024;
  static const int desktopDiskModeThresholdBytes = 40 * 1024 * 1024;

  static LoadMode selectLoadMode({
    required bool isAndroid,
    required String pathOrUrl,
    required TrackSourceType sourceType,
    int? fileSizeBytes,
  }) {
    final cleaned = pathOrUrl.split('?').first.split('#').first.toLowerCase();
    final isMp3 = cleaned.endsWith('.mp3');

    if (isAndroid) {
      if (sourceType == TrackSourceType.stream) {
        return isMp3 ? LoadMode.memory : LoadMode.disk;
      }
      if (isMp3) {
        if (fileSizeBytes != null &&
            fileSizeBytes >= androidDiskModeMp3ThresholdBytes) {
          return LoadMode.disk;
        }
        return LoadMode.memory;
      }
      return LoadMode.disk;
    }

    if (sourceType == TrackSourceType.local &&
        fileSizeBytes != null &&
        fileSizeBytes >= desktopDiskModeThresholdBytes) {
      return LoadMode.disk;
    }
    return LoadMode.memory;
  }

  final SoLoud _soloud = SoLoud.instance;
  final AndroidMediaService _androidMedia;

  AudioEngine({AndroidMediaService? androidMedia})
      : _androidMedia = androidMedia ?? AndroidMediaService();

  AudioSource? _currentSource;
  SoundHandle? _currentHandle;
  StreamSubscription<StreamSoundEvent>? _soundEventSub;
  StreamSubscription<AudioVisualizationData>? _visSub;
  Timer? _positionTimer;

  bool _isInitialized = false;
  Future<void>? _initFuture;
  bool _isStoppingManually = false;
  int _playRequestId = 0;

  // Data FFT Real-Time & Posisi Lagu (pakai ValueNotifier agar UI tidak rebuild 20x/detik)
  @override
  final ValueNotifier<Float32List> fftNotifier = ValueNotifier(Float32List(0));
  @override
  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);

  // State Player
  @override
  bool isPlaying = false;
  @override
  bool isMuted = false;
  @override
  double volume = 0.6; // Mulai di 60% biar gak kena sound horeg
  @override
  Duration duration = Duration.zero;

  @override
  Duration get position => positionNotifier.value;
  @override
  bool get hasLoadedSource => _currentSource != null;

  // Callback untuk memberitahu UI saat status playback berubah
  @override
  VoidCallback? onStateChanged;
  @override
  VoidCallback? onTrackComplete;

  @override
  void setPreparedTrackState({
    required Duration duration,
    required Duration position,
  }) {
    this.duration = duration;
    Duration clamped = position < Duration.zero ? Duration.zero : position;
    if (duration > Duration.zero && clamped > duration) {
      clamped = duration;
    }
    positionNotifier.value = clamped;
    onStateChanged?.call();
  }

  @override
  void applyAudioSettings({required double volume, required bool isMuted}) {
    this.volume = volume.clamp(0.0, 1.0);
    this.isMuted = isMuted || this.volume == 0.0;
    if (_soloud.isInitialized) {
      _soloud.setGlobalVolume(this.isMuted ? 0.0 : this.volume);
    }
    onStateChanged?.call();
  }

  @override
  Future<void> init() async {
    if (_isInitialized) return;
    if (_initFuture != null) return _initFuture!;

    final future = _doInit();
    _initFuture = future;
    try {
      await future;
    } catch (_) {
      _initFuture = null;
      rethrow;
    }
  }

  Future<void> _doInit() async {
    await _soloud.init();
    _soloud.setGlobalVolume(isMuted ? 0.0 : volume);

    // Aktifkan analisis frekuensi FFT Real-Time di mesin C++
    _soloud.setVisualizationEnabled(
      true,
      windowSize: 512, // Menghasilkan 256 band frekuensi (bass -> treble)
      kind: VisualizationKind.fft,
      channel: VisualizationChannel.merged,
    );
    _soloud.setFftSmoothing(0.72); // Haluskan gerakan batang langsung di C++
    _soloud.setFftDecibelRange(-82, -18);

    // Dengarkan aliran data frekuensi asli dari lagu yang sedang bunyi
    _visSub = _soloud.audioVisualizationEvents.listen((data) {
      final fft = data.fftData;
      if (fft != null && isPlaying) {
        fftNotifier.value = Float32List.fromList(fft);
      }
    });

    // Pantau posisi waktu lagu setiap 50ms tanpa me-rebuild seluruh HomeScreen
    _positionTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_currentHandle != null &&
          isPlaying &&
          _soloud.isInitialized &&
          _soloud.getIsValidVoiceHandle(_currentHandle!)) {
        positionNotifier.value = _soloud.getPosition(_currentHandle!);
      }
    });

    _isInitialized = true;
  }

  void _listenToTrackEnd(AudioSource source, SoundHandle handle) {
    _soundEventSub = source.soundEvents.listen((event) {
      if (event.event == SoundEventType.handleIsNoMoreValid &&
          event.handle == handle &&
          !_isStoppingManually) {
        isPlaying = false;
        fftNotifier.value = Float32List(0);
        onStateChanged?.call();
        onTrackComplete?.call();
      }
    });
  }

  Future<void> _stopAndDisposeCurrentSource() async {
    _isStoppingManually = true;
    isPlaying = false;
    fftNotifier.value = Float32List(0);

    final sub = _soundEventSub;
    final prevHandle = _currentHandle;
    final prevSource = _currentSource;
    _soundEventSub = null;
    _currentHandle = null;
    _currentSource = null;

    await sub?.cancel();

    if (prevHandle != null &&
        _soloud.isInitialized &&
        _soloud.getIsValidVoiceHandle(prevHandle)) {
      await _soloud.stop(prevHandle);
    }
    if (prevSource != null && _soloud.isInitialized) {
      await _soloud.disposeSource(prevSource);
    }
  }

  Future<String> _resolveLocalPlaybackPath(String pathOrUri) async {
    if (!kIsWeb &&
        Platform.isAndroid &&
        pathOrUri.startsWith('content://')) {
      final tempDir = await getTemporaryDirectory();
      final cacheDir = p.join(tempDir.path, 'noven_playback_cache');
      final resolved = await _androidMedia.materializeContentUri(
        pathOrUri,
        cacheDirPath: cacheDir,
      );
      if (resolved != null && resolved.isNotEmpty) {
        return resolved;
      }
    }
    return pathOrUri;
  }

  @override
  Future<void> playTrack(Track track, {Duration? startPosition}) async {
    final requestId = ++_playRequestId;

    if (!_isInitialized) await init();
    if (requestId != _playRequestId) return;

    await _stopAndDisposeCurrentSource();
    if (requestId != _playRequestId) return;

    final isAndroid = !kIsWeb && Platform.isAndroid;
    late final AudioSource source;

    if (track.sourceType == TrackSourceType.local) {
      final effectivePath = await _resolveLocalPlaybackPath(track.pathOrUrl);
      if (requestId != _playRequestId) return;

      int? fileSizeBytes;
      try {
        final file = File(effectivePath);
        if (await file.exists()) {
          fileSizeBytes = await file.length();
        }
      } catch (_) {}

      final mode = selectLoadMode(
        isAndroid: isAndroid,
        pathOrUrl: effectivePath,
        sourceType: TrackSourceType.local,
        fileSizeBytes: fileSizeBytes,
      );
      source = await _soloud.loadFile(effectivePath, mode: mode);
    } else {
      final mode = selectLoadMode(
        isAndroid: isAndroid,
        pathOrUrl: track.pathOrUrl,
        sourceType: TrackSourceType.stream,
      );
      source = await _soloud.loadUrl(track.pathOrUrl, mode: mode);
    }

    // Jika sudah ada klik play lagu lain saat load berjalan, buang source ini
    // supaya suara tidak bertumpuk.
    if (requestId != _playRequestId) {
      if (_soloud.isInitialized) {
        await _soloud.disposeSource(source);
      }
      return;
    }

    if (_currentSource != null) {
      await _stopAndDisposeCurrentSource();
      if (requestId != _playRequestId) {
        if (_soloud.isInitialized) {
          await _soloud.disposeSource(source);
        }
        return;
      }
    }

    _currentSource = source;
    duration = _soloud.getLength(source);
    positionNotifier.value = Duration.zero;

    final handle = _soloud.play(source);
    _currentHandle = handle;
    if (startPosition != null &&
        startPosition > Duration.zero &&
        (duration == Duration.zero || startPosition < duration)) {
      _soloud.seek(handle, startPosition);
      positionNotifier.value = startPosition;
    }
    isPlaying = true;
    _isStoppingManually = false;

    _listenToTrackEnd(source, handle);
    onStateChanged?.call();
  }

  @override
  Future<bool> replayCurrent() async {
    final requestId = ++_playRequestId;
    final source = _currentSource;
    if (source == null || !_soloud.isInitialized) return false;

    _isStoppingManually = true;
    final sub = _soundEventSub;
    final prevHandle = _currentHandle;
    _soundEventSub = null;
    _currentHandle = null;

    await sub?.cancel();
    if (prevHandle != null && _soloud.getIsValidVoiceHandle(prevHandle)) {
      await _soloud.stop(prevHandle);
    }

    if (requestId != _playRequestId ||
        _currentSource != source ||
        !_soloud.isInitialized) {
      return false;
    }

    positionNotifier.value = Duration.zero;
    final handle = _soloud.play(source);
    _currentHandle = handle;
    isPlaying = true;
    _isStoppingManually = false;

    _listenToTrackEnd(source, handle);
    onStateChanged?.call();
    return true;
  }

  @override
  Future<void> stop() async {
    ++_playRequestId;
    await _stopAndDisposeCurrentSource();
    duration = Duration.zero;
    positionNotifier.value = Duration.zero;
    onStateChanged?.call();
  }

  @override
  void resetPosition() {
    positionNotifier.value = Duration.zero;
  }

  @override
  void togglePause() {
    if (_currentSource == null || !_soloud.isInitialized) return;
    if (_currentHandle == null ||
        !_soloud.getIsValidVoiceHandle(_currentHandle!)) {
      replayCurrent();
      return;
    }

    final nextPaused = isPlaying;
    _soloud.setPause(_currentHandle!, nextPaused);
    isPlaying = !nextPaused;

    if (!isPlaying) {
      fftNotifier.value = Float32List(0); // Grafik langsung tenang saat pause
    }
    onStateChanged?.call();
  }

  @override
  void seek(Duration target) {
    if (_currentHandle == null || !_soloud.isInitialized) return;
    if (!_soloud.getIsValidVoiceHandle(_currentHandle!)) return;

    _soloud.seek(_currentHandle!, target); // Synchronous C++ -> instan!
    positionNotifier.value = target;
  }

  @override
  void setVolume(double value) {
    volume = value.clamp(0.0, 1.0);
    isMuted = volume == 0.0;
    if (_soloud.isInitialized) {
      _soloud.setGlobalVolume(volume); // Synchronous C++ -> 0ms LAG!
    }
    onStateChanged?.call();
  }

  @override
  void toggleMute() {
    if (isMuted) {
      isMuted = false;
      if (volume == 0.0) {
        volume = 0.5;
      }
    } else {
      isMuted = true;
    }
    if (_soloud.isInitialized) {
      _soloud.setGlobalVolume(isMuted ? 0.0 : volume);
    }
    onStateChanged?.call();
  }

  @override
  Future<void> dispose() async {
    ++_playRequestId;
    _isStoppingManually = true;
    _positionTimer?.cancel();
    await _visSub?.cancel();
    await _stopAndDisposeCurrentSource();
    fftNotifier.dispose();
    positionNotifier.dispose();
  }
}
