import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum AndroidPermissionStatus {
  granted,
  denied,
  permanentlyDenied,
  unsupported,
}

enum AndroidMediaAction {
  play,
  pause,
  togglePlayPause,
  next,
  previous,
  seek,
  stop,
}

class AndroidMediaTrack {
  final String path;
  final String? contentUri;
  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
  final int? sizeBytes;
  final String? coverPath;
  final DateTime? addedAt;

  const AndroidMediaTrack({
    required this.path,
    this.contentUri,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.sizeBytes,
    this.coverPath,
    this.addedAt,
  });

  factory AndroidMediaTrack.fromMap(Map<Object?, Object?> raw) {
    final path = (raw['path'] as String? ?? '').trim();
    final contentUri = (raw['contentUri'] as String?)?.trim();
    final rawTitle = (raw['title'] as String? ?? '').trim();
    final rawArtist = (raw['artist'] as String? ?? '').trim();
    final rawAlbum = (raw['album'] as String?)?.trim();
    final durationMs = raw['durationMs'] as int?;
    final sizeBytes = raw['sizeBytes'] as int?;
    final coverPath = (raw['coverPath'] as String?)?.trim();
    final addedAtMs = raw['addedAtMs'] as int?;

    return AndroidMediaTrack(
      path: path,
      contentUri: contentUri != null && contentUri.isNotEmpty
          ? contentUri
          : null,
      title: rawTitle.isNotEmpty ? rawTitle : 'Untitled',
      artist: rawArtist.isNotEmpty ? rawArtist : 'Unknown Artist',
      album: rawAlbum != null && rawAlbum.isNotEmpty ? rawAlbum : null,
      duration:
          durationMs != null && durationMs > 0
              ? Duration(milliseconds: durationMs)
              : null,
      sizeBytes: sizeBytes,
      coverPath: coverPath != null && coverPath.isNotEmpty ? coverPath : null,
      addedAt: addedAtMs != null && addedAtMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(addedAtMs)
          : null,
    );
  }
}

class AndroidMediaService {
  static const String channelName = 'com.example.noven/android_media';

  final MethodChannel _channel;
  final bool _isSupported;

  void Function(AndroidMediaAction action, Duration? seekPosition)? onMediaAction;

  AndroidMediaService({
    MethodChannel? channel,
    bool? isAndroidOverride,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _isSupported = isAndroidOverride ?? (!kIsWeb && Platform.isAndroid) {
    if (_isSupported) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  bool get isSupported => _isSupported;

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onMediaAction') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final rawAction = args['action'] as String?;
    final action = switch (rawAction) {
      'play' => AndroidMediaAction.play,
      'pause' => AndroidMediaAction.pause,
      'togglePlayPause' => AndroidMediaAction.togglePlayPause,
      'next' => AndroidMediaAction.next,
      'previous' => AndroidMediaAction.previous,
      'seek' => AndroidMediaAction.seek,
      'stop' => AndroidMediaAction.stop,
      _ => null,
    };
    if (action == null) return null;

    final rawPos = args['positionMs'];
    final seekPos = rawPos is num && rawPos >= 0
        ? Duration(milliseconds: rawPos.toInt())
        : null;
    onMediaAction?.call(action, seekPos);
    return true;
  }

  AndroidPermissionStatus _parseStatus(String? raw) {
    switch (raw) {
      case 'granted':
        return AndroidPermissionStatus.granted;
      case 'permanentlyDenied':
        return AndroidPermissionStatus.permanentlyDenied;
      case 'denied':
        return AndroidPermissionStatus.denied;
      default:
        return AndroidPermissionStatus.unsupported;
    }
  }

  Future<AndroidPermissionStatus> checkAudioPermission() async {
    if (!_isSupported) return AndroidPermissionStatus.unsupported;
    try {
      final raw = await _channel.invokeMethod<String>('checkAudioPermission');
      return _parseStatus(raw);
    } on MissingPluginException {
      return AndroidPermissionStatus.unsupported;
    } on PlatformException catch (e) {
      debugPrint('[AndroidMediaService.checkAudioPermission] $e');
      return AndroidPermissionStatus.denied;
    }
  }

  Future<AndroidPermissionStatus> requestAudioPermission() async {
    if (!_isSupported) return AndroidPermissionStatus.unsupported;
    try {
      final raw = await _channel.invokeMethod<String>('requestAudioPermission');
      return _parseStatus(raw);
    } on MissingPluginException {
      return AndroidPermissionStatus.unsupported;
    } on PlatformException catch (e) {
      debugPrint('[AndroidMediaService.requestAudioPermission] $e');
      return AndroidPermissionStatus.denied;
    }
  }

  Future<AndroidPermissionStatus> checkNotificationPermission() async {
    if (!_isSupported) return AndroidPermissionStatus.unsupported;
    try {
      final raw = await _channel.invokeMethod<String>(
        'checkNotificationPermission',
      );
      return _parseStatus(raw);
    } on MissingPluginException {
      return AndroidPermissionStatus.unsupported;
    } on PlatformException catch (e) {
      debugPrint('[AndroidMediaService.checkNotificationPermission] $e');
      return AndroidPermissionStatus.denied;
    }
  }

  Future<AndroidPermissionStatus> requestNotificationPermission() async {
    if (!_isSupported) return AndroidPermissionStatus.unsupported;
    try {
      final raw = await _channel.invokeMethod<String>(
        'requestNotificationPermission',
      );
      return _parseStatus(raw);
    } on MissingPluginException {
      return AndroidPermissionStatus.unsupported;
    } on PlatformException catch (e) {
      debugPrint('[AndroidMediaService.requestNotificationPermission] $e');
      return AndroidPermissionStatus.denied;
    }
  }

  Future<bool> openAppSettings() async {
    if (!_isSupported) return false;
    try {
      final opened = await _channel.invokeMethod<bool>('openAppSettings');
      return opened ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('[AndroidMediaService.openAppSettings] $e');
      return false;
    }
  }

  Future<List<AndroidMediaTrack>> scanDeviceAudio({
    String? coverDirPath,
  }) async {
    if (!_isSupported) return const [];
    try {
      final rawList = await _channel.invokeListMethod<Object?>(
        'scanMediaStoreAudio',
        {'coverDirPath': coverDirPath},
      );
      if (rawList == null) return const [];
      final tracks = <AndroidMediaTrack>[];
      for (final item in rawList) {
        if (item is Map<Object?, Object?>) {
          final track = AndroidMediaTrack.fromMap(item);
          if (track.path.isNotEmpty) {
            tracks.add(track);
          }
        }
      }
      return tracks;
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (e) {
      debugPrint('[AndroidMediaService.scanDeviceAudio] $e');
      rethrow;
    }
  }

  Future<String?> materializeContentUri(
    String contentUri, {
    required String cacheDirPath,
  }) async {
    if (!_isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('materializeContentUri', {
        'uri': contentUri,
        'cacheDirPath': cacheDirPath,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('[AndroidMediaService.materializeContentUri] $e');
      return null;
    }
  }

  Future<void> updateMediaNotification({
    required String title,
    required String artist,
    String? album,
    required Duration duration,
    required Duration position,
    required bool isPlaying,
    String? coverPath,
  }) async {
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod<void>('updateMediaNotification', {
        'title': title,
        'artist': artist,
        'album': album,
        'durationMs': duration.inMilliseconds < 0 ? 0 : duration.inMilliseconds,
        'positionMs': position.inMilliseconds < 0 ? 0 : position.inMilliseconds,
        'isPlaying': isPlaying,
        'coverPath': coverPath,
      });
    } on MissingPluginException {
      // Abaikan di platform tanpa implementasi bridge native.
    } on PlatformException catch (e) {
      debugPrint('[AndroidMediaService.updateMediaNotification] $e');
    }
  }

  Future<void> clearMediaNotification() async {
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod<void>('clearMediaNotification');
    } on MissingPluginException {
      // Abaikan di platform tanpa implementasi bridge native.
    } on PlatformException catch (e) {
      debugPrint('[AndroidMediaService.clearMediaNotification] $e');
    }
  }

  void dispose() {
    onMediaAction = null;
    if (_isSupported) {
      _channel.setMethodCallHandler(null);
    }
  }
}
