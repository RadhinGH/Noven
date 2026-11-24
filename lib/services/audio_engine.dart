import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../models/track.dart';

class AudioEngine {
  final SoLoud _soloud = SoLoud.instance;

  AudioSource? _currentSource;
  SoundHandle? _currentHandle;
  StreamSubscription<StreamSoundEvent>? _soundEventSub;
  StreamSubscription<AudioVisualizationData>? _visSub;
  Timer? _positionTimer;

  bool _isInitialized = false;
  bool _isStoppingManually = false;

  // Data FFT Real-Time & Posisi Lagu (pakai ValueNotifier agar UI tidak rebuild 20x/detik)
  final ValueNotifier<Float32List> fftNotifier = ValueNotifier(Float32List(0));
  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);

  // State Player
  bool isPlaying = false;
  bool isMuted = false;
  double volume = 0.6; // Mulai di 60% biar gak kena sound horeg
  Duration duration = Duration.zero;

  Duration get position => positionNotifier.value;
  bool get hasLoadedSource => _currentSource != null;

  // Callback untuk memberitahu UI saat status playback berubah
  VoidCallback? onStateChanged;
  VoidCallback? onTrackComplete;

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

  void applyAudioSettings({required double volume, required bool isMuted}) {
    this.volume = volume.clamp(0.0, 1.0);
    this.isMuted = isMuted || this.volume == 0.0;
    if (_soloud.isInitialized) {
      _soloud.setGlobalVolume(this.isMuted ? 0.0 : this.volume);
    }
    onStateChanged?.call();
  }

  Future<void> init() async {
    if (_isInitialized) return;

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

  Future<void> playTrack(Track track, {Duration? startPosition}) async {
    if (!_isInitialized) await init();

    _isStoppingManually = true;
    await _soundEventSub?.cancel();
    _soundEventSub = null;

    // Bersihkan lagu sebelumnya dari RAM agar pemakaian memori tetap rendah
    if (_currentSource != null) {
      await _soloud.disposeSource(_currentSource!);
      _currentSource = null;
      _currentHandle = null;
    }

    // LoadMode.memory pada 1 lagu aktif saja -> Seek MP3 jadi INSTAN 0ms!
    final source = track.sourceType == TrackSourceType.local
        ? await _soloud.loadFile(track.pathOrUrl, mode: LoadMode.memory)
        : await _soloud.loadUrl(track.pathOrUrl, mode: LoadMode.memory);

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

  Future<bool> replayCurrent() async {
    if (_currentSource == null || !_soloud.isInitialized) return false;

    _isStoppingManually = true;
    await _soundEventSub?.cancel();
    _soundEventSub = null;

    if (_currentHandle != null &&
        _soloud.getIsValidVoiceHandle(_currentHandle!)) {
      await _soloud.stop(_currentHandle!);
    }

    positionNotifier.value = Duration.zero;
    final handle = _soloud.play(_currentSource!);
    _currentHandle = handle;
    isPlaying = true;
    _isStoppingManually = false;

    _listenToTrackEnd(_currentSource!, handle);
    onStateChanged?.call();
    return true;
  }

  void resetPosition() {
    positionNotifier.value = Duration.zero;
  }

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

  void seek(Duration target) {
    if (_currentHandle == null || !_soloud.isInitialized) return;
    if (!_soloud.getIsValidVoiceHandle(_currentHandle!)) return;

    _soloud.seek(_currentHandle!, target); // Synchronous C++ -> instan!
    positionNotifier.value = target;
  }

  void setVolume(double value) {
    volume = value.clamp(0.0, 1.0);
    isMuted = volume == 0.0;
    if (_soloud.isInitialized) {
      _soloud.setGlobalVolume(volume); // Synchronous C++ -> 0ms LAG!
    }
    onStateChanged?.call();
  }

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

  Future<void> dispose() async {
    _isStoppingManually = true;
    _positionTimer?.cancel();
    await _soundEventSub?.cancel();
    await _visSub?.cancel();
    if (_currentSource != null && _soloud.isInitialized) {
      await _soloud.disposeSource(_currentSource!);
    }
    fftNotifier.dispose();
    positionNotifier.dispose();
  }
}
