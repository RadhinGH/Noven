import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/playlist.dart';
import '../models/repeat_mode.dart';

class CustomStreamEntry {
  final String title;
  final String artist;
  final String url;

  const CustomStreamEntry({
    required this.title,
    required this.artist,
    required this.url,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'url': url,
      };

  factory CustomStreamEntry.fromJson(Map<String, dynamic> json) {
    return CustomStreamEntry(
      title: (json['title'] as String? ?? 'Untitled Stream').trim(),
      artist: (json['artist'] as String? ?? 'Web Stream').trim(),
      url: (json['url'] as String? ?? '').trim(),
    );
  }
}

class NovenSavedState {
  final List<String> localFolders;
  final List<String> localFiles;
  final List<CustomStreamEntry> customStreams;
  final Map<String, bool> sourceEnabled;
  final double volume;
  final bool isMuted;
  final bool shuffle;
  final PlaybackRepeatMode repeatMode;
  final List<Playlist> playlists;
  final String? lastTrackId;
  final int lastPositionMs;

  const NovenSavedState({
    required this.localFolders,
    required this.localFiles,
    required this.customStreams,
    required this.sourceEnabled,
    required this.volume,
    required this.isMuted,
    required this.shuffle,
    required this.repeatMode,
    this.playlists = const [],
    this.lastTrackId,
    this.lastPositionMs = 0,
  });

  static const defaults = NovenSavedState(
    localFolders: [],
    localFiles: [],
    customStreams: [],
    sourceEnabled: {'local': true, 'online': true},
    volume: 0.6,
    isMuted: false,
    shuffle: false,
    repeatMode: PlaybackRepeatMode.all,
    playlists: [],
    lastTrackId: null,
    lastPositionMs: 0,
  );

  Map<String, dynamic> toJson() => {
        'localFolders': localFolders,
        'localFiles': localFiles,
        'customStreams': customStreams.map((e) => e.toJson()).toList(),
        'sourceEnabled': sourceEnabled,
        'volume': volume,
        'isMuted': isMuted,
        'shuffle': shuffle,
        'repeatMode': repeatMode.name,
        'playlists': playlists.map((p) => p.toJson()).toList(),
        'lastTrackId': lastTrackId,
        'lastPositionMs': lastPositionMs,
      };

  factory NovenSavedState.fromJson(Map<String, dynamic> json) {
    final rawFolders = json['localFolders'];
    final folders = rawFolders is List
        ? rawFolders.whereType<String>().where((s) => s.trim().isNotEmpty).toList()
        : <String>[];

    final rawFiles = json['localFiles'];
    final files = rawFiles is List
        ? rawFiles.whereType<String>().where((s) => s.trim().isNotEmpty).toList()
        : <String>[];

    final rawStreams = json['customStreams'];
    final streams = <CustomStreamEntry>[];
    if (rawStreams is List) {
      for (final item in rawStreams) {
        if (item is Map<String, dynamic>) {
          final entry = CustomStreamEntry.fromJson(item);
          if (entry.url.isNotEmpty) streams.add(entry);
        } else if (item is Map) {
          final entry = CustomStreamEntry.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (entry.url.isNotEmpty) streams.add(entry);
        }
      }
    }

    final rawEnabled = json['sourceEnabled'];
    final enabled = <String, bool>{'local': true, 'online': true};
    if (rawEnabled is Map) {
      for (final entry in rawEnabled.entries) {
        if (entry.key is String && entry.value is bool) {
          enabled[entry.key as String] = entry.value as bool;
        }
      }
    }

    final rawVolume = json['volume'];
    final volume = rawVolume is num
        ? rawVolume.toDouble().clamp(0.0, 1.0)
        : defaults.volume;

    final rawMuted = json['isMuted'];
    final isMuted = rawMuted is bool ? rawMuted : defaults.isMuted;

    final rawShuffle = json['shuffle'];
    final shuffle = rawShuffle is bool ? rawShuffle : defaults.shuffle;

    final rawRepeat = json['repeatMode'];
    final repeatMode = PlaybackRepeatMode.fromName(
      rawRepeat is String ? rawRepeat : null,
    );

    final rawPlaylists = json['playlists'];
    final playlists = <Playlist>[];
    if (rawPlaylists is List) {
      for (final item in rawPlaylists) {
        if (item is Map<String, dynamic>) {
          playlists.add(Playlist.fromJson(item));
        } else if (item is Map) {
          playlists.add(Playlist.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final rawLastTrackId = json['lastTrackId'];
    final lastTrackId = rawLastTrackId is String && rawLastTrackId.trim().isNotEmpty
        ? rawLastTrackId.trim()
        : null;

    final rawLastPos = json['lastPositionMs'];
    final lastPositionMs = rawLastPos is num
        ? (rawLastPos.toInt() < 0 ? 0 : rawLastPos.toInt())
        : 0;

    return NovenSavedState(
      localFolders: folders,
      localFiles: files,
      customStreams: streams,
      sourceEnabled: enabled,
      volume: volume,
      isMuted: isMuted,
      shuffle: shuffle,
      repeatMode: repeatMode,
      playlists: playlists,
      lastTrackId: lastTrackId,
      lastPositionMs: lastPositionMs,
    );
  }
}

class StorageService {
  static const _fileName = 'noven_data.json';
  Future<void> _writeQueue = Future.value();

  Future<File> _getDataFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<NovenSavedState> load() async {
    try {
      final file = await _getDataFile();
      if (!file.existsSync()) return NovenSavedState.defaults;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return NovenSavedState.defaults;
      final decoded = jsonDecode(content);
      if (decoded is! Map) return NovenSavedState.defaults;
      return NovenSavedState.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e, st) {
      debugPrint('[StorageService.load] Error reading $_fileName: $e\n$st');
      return NovenSavedState.defaults;
    }
  }

  Future<void> save(NovenSavedState state) {
    _writeQueue = _writeQueue.then((_) async {
      try {
        final file = await _getDataFile();
        if (!file.parent.existsSync()) {
          await file.parent.create(recursive: true);
        }
        const encoder = JsonEncoder.withIndent('  ');
        await file.writeAsString(encoder.convert(state.toJson()), flush: true);
      } catch (e, st) {
        debugPrint('[StorageService.save] Error writing $_fileName: $e\n$st');
      }
    });
    return _writeQueue;
  }
}
