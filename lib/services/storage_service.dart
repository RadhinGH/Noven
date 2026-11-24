import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
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

enum StorageLoadStatus {
  ok,
  notFound,
  migrated,
  recoveredFromBackup,
  corrupted,
}

class StorageLoadResult {
  final NovenSavedState state;
  final StorageLoadStatus status;
  final String? message;
  final String? corruptBackupPath;

  const StorageLoadResult({
    required this.state,
    required this.status,
    this.message,
    this.corruptBackupPath,
  });
}

class NovenSavedState {
  static const int currentSchemaVersion = 2;

  final int schemaVersion;
  final bool legacyLibraryMigrated;
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
    this.schemaVersion = currentSchemaVersion,
    this.legacyLibraryMigrated = false,
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
    schemaVersion: currentSchemaVersion,
    legacyLibraryMigrated: false,
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

  NovenSavedState copyWith({
    int? schemaVersion,
    bool? legacyLibraryMigrated,
    List<String>? localFolders,
    List<String>? localFiles,
    List<CustomStreamEntry>? customStreams,
    Map<String, bool>? sourceEnabled,
    double? volume,
    bool? isMuted,
    bool? shuffle,
    PlaybackRepeatMode? repeatMode,
    List<Playlist>? playlists,
    String? lastTrackId,
    bool clearLastTrackId = false,
    int? lastPositionMs,
  }) {
    return NovenSavedState(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      legacyLibraryMigrated:
          legacyLibraryMigrated ?? this.legacyLibraryMigrated,
      localFolders: localFolders ?? this.localFolders,
      localFiles: localFiles ?? this.localFiles,
      customStreams: customStreams ?? this.customStreams,
      sourceEnabled: sourceEnabled ?? this.sourceEnabled,
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
      shuffle: shuffle ?? this.shuffle,
      repeatMode: repeatMode ?? this.repeatMode,
      playlists: playlists ?? this.playlists,
      lastTrackId:
          clearLastTrackId ? null : (lastTrackId ?? this.lastTrackId),
      lastPositionMs: lastPositionMs ?? this.lastPositionMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'legacyLibraryMigrated': legacyLibraryMigrated,
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
    final rawVersion = json['schemaVersion'];
    final schemaVersion =
        rawVersion is num ? rawVersion.toInt() : currentSchemaVersion;

    final rawLegacyMigrated = json['legacyLibraryMigrated'];
    final legacyLibraryMigrated =
        rawLegacyMigrated is bool ? rawLegacyMigrated : false;

    final rawFolders = json['localFolders'];
    final folders = rawFolders is List
        ? rawFolders
            .whereType<String>()
            .where((s) => s.trim().isNotEmpty)
            .toList()
        : <String>[];

    final rawFiles = json['localFiles'];
    final files = rawFiles is List
        ? rawFiles
            .whereType<String>()
            .where((s) => s.trim().isNotEmpty)
            .toList()
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
    final lastTrackId =
        rawLastTrackId is String && rawLastTrackId.trim().isNotEmpty
            ? rawLastTrackId.trim()
            : null;

    final rawLastPos = json['lastPositionMs'];
    final lastPositionMs = rawLastPos is num
        ? (rawLastPos.toInt() < 0 ? 0 : rawLastPos.toInt())
        : 0;

    return NovenSavedState(
      schemaVersion: schemaVersion,
      legacyLibraryMigrated: legacyLibraryMigrated,
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
  static const _tmpFileName = 'noven_data.json.tmp';
  static const _bakFileName = 'noven_data.json.bak';
  static const _bakTmpFileName = 'noven_data.json.bak.tmp';
  static const _corruptFileName = 'noven_data.json.corrupt';

  final Future<Directory> Function() _directoryProvider;
  Future<void> _writeQueue = Future.value();
  bool _corruptUnrecovered = false;

  StorageService({Future<Directory> Function()? directoryProvider})
      : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory;

  bool get hasUnrecoveredCorruption => _corruptUnrecovered;

  /// Migrates raw settings JSON from older schemas up to
  /// [NovenSavedState.currentSchemaVersion].
  static ({Map<String, dynamic> json, bool migrated}) migrateJson(
    Map<String, dynamic> raw,
  ) {
    final copy = Map<String, dynamic>.from(raw);
    final rawVersion = copy['schemaVersion'];
    final version = rawVersion is num ? rawVersion.toInt() : 1;

    if (version == NovenSavedState.currentSchemaVersion) {
      return (json: copy, migrated: false);
    }

    if (version > NovenSavedState.currentSchemaVersion) {
      debugPrint(
        '[StorageService.migrateJson] Schema version $version is newer than '
        'supported ${NovenSavedState.currentSchemaVersion}; parsing defensively.',
      );
      return (json: copy, migrated: false);
    }

    var current = version;
    var migrated = false;

    if (current < 2) {
      copy['schemaVersion'] = 2;
      copy['legacyLibraryMigrated'] ??= false;
      if (copy['sourceEnabled'] is! Map) {
        copy['sourceEnabled'] = {'local': true, 'online': true};
      }
      if (copy['playlists'] is! List) {
        copy['playlists'] = <dynamic>[];
      }
      final rawPos = copy['lastPositionMs'];
      if (rawPos is! num || rawPos < 0) {
        copy['lastPositionMs'] = 0;
      }
      current = 2;
      migrated = true;
    }

    return (json: copy, migrated: migrated);
  }

  Future<File> _file(String name) async {
    final dir = await _directoryProvider();
    return File(p.join(dir.path, name));
  }

  Future<({NovenSavedState state, bool migrated})> _parseFile(File file) async {
    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      throw const FormatException('Settings file is empty');
    }
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException('Settings JSON root is not an object');
    }
    final migration = migrateJson(Map<String, dynamic>.from(decoded));
    final state = NovenSavedState.fromJson(migration.json);
    return (state: state, migrated: migration.migrated);
  }

  Future<String?> _quarantineCorruptFile(File mainFile) async {
    try {
      var corruptFile = await _file(_corruptFileName);
      if (corruptFile.existsSync()) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        corruptFile = await _file('noven_data.json.$ts.corrupt');
      }
      await _safeReplaceFile(mainFile, corruptFile);
      return corruptFile.path;
    } catch (e, st) {
      debugPrint(
        '[StorageService.load] Failed to quarantine corrupt $_fileName: $e\n$st',
      );
      return null;
    }
  }

  Future<StorageLoadResult> loadWithStatus() async {
    try {
      final mainFile = await _file(_fileName);
      final bakFile = await _file(_bakFileName);

      if (mainFile.existsSync()) {
        try {
          final parsed = await _parseFile(mainFile);
          _corruptUnrecovered = false;
          return StorageLoadResult(
            state: parsed.state,
            status: parsed.migrated
                ? StorageLoadStatus.migrated
                : StorageLoadStatus.ok,
          );
        } catch (e, st) {
          debugPrint(
            '[StorageService.load] Corrupt $_fileName detected: $e\n$st',
          );
          final corruptPath = await _quarantineCorruptFile(mainFile);

          if (bakFile.existsSync()) {
            try {
              final bakParsed = await _parseFile(bakFile);
              _corruptUnrecovered = false;
              debugPrint(
                '[StorageService.load] Recovered settings from $_bakFileName.',
              );
              return StorageLoadResult(
                state: bakParsed.state,
                status: StorageLoadStatus.recoveredFromBackup,
                corruptBackupPath: corruptPath,
                message:
                    'File pengaturan rusak dan telah dipulihkan dari backup.',
              );
            } catch (bakErr, bakSt) {
              debugPrint(
                '[StorageService.load] Backup $_bakFileName also invalid: $bakErr\n$bakSt',
              );
            }
          }

          _corruptUnrecovered = true;
          return StorageLoadResult(
            state: NovenSavedState.defaults,
            status: StorageLoadStatus.corrupted,
            corruptBackupPath: corruptPath,
            message:
                'File pengaturan rusak & disimpan ke .corrupt (tidak ditimpa).',
          );
        }
      }

      if (bakFile.existsSync()) {
        try {
          final bakParsed = await _parseFile(bakFile);
          _corruptUnrecovered = false;
          debugPrint(
            '[StorageService.load] Main file missing; recovered from $_bakFileName.',
          );
          return StorageLoadResult(
            state: bakParsed.state,
            status: StorageLoadStatus.recoveredFromBackup,
            message: 'File utama tidak ditemukan; dipulihkan dari backup.',
          );
        } catch (e, st) {
          debugPrint(
            '[StorageService.load] Orphan $_bakFileName invalid: $e\n$st',
          );
        }
      }

      _corruptUnrecovered = false;
      return const StorageLoadResult(
        state: NovenSavedState.defaults,
        status: StorageLoadStatus.notFound,
      );
    } catch (e, st) {
      debugPrint('[StorageService.load] Unexpected error: $e\n$st');
      return const StorageLoadResult(
        state: NovenSavedState.defaults,
        status: StorageLoadStatus.notFound,
      );
    }
  }

  Future<NovenSavedState> load() async {
    final result = await loadWithStatus();
    return result.state;
  }

  /// Atomically writes [state] to `noven_data.json` via temp file + rename,
  /// preserving the previous valid file in `noven_data.json.bak`.
  ///
  /// When [hasUnrecoveredCorruption] is true, saves are skipped unless
  /// [allowOverwriteCorrupt] is true so corrupted settings are never silently
  /// overwritten with defaults.
  Future<bool> save(
    NovenSavedState state, {
    bool allowOverwriteCorrupt = false,
  }) {
    final op = _writeQueue.then((_) async {
      if (_corruptUnrecovered && !allowOverwriteCorrupt) {
        debugPrint(
          '[StorageService.save] Skipping save because unrecovered corrupt '
          'file was detected.',
        );
        return false;
      }

      try {
        final mainFile = await _file(_fileName);
        final tmpFile = await _file(_tmpFileName);
        final bakFile = await _file(_bakFileName);
        final bakTmpFile = await _file(_bakTmpFileName);

        if (!mainFile.parent.existsSync()) {
          await mainFile.parent.create(recursive: true);
        }

        const encoder = JsonEncoder.withIndent('  ');
        final payload = encoder.convert(
          state.copyWith(schemaVersion: NovenSavedState.currentSchemaVersion).toJson(),
        );
        await tmpFile.writeAsString(payload, flush: true);

        if (mainFile.existsSync()) {
          await mainFile.copy(bakTmpFile.path);
          await _safeReplaceFile(bakTmpFile, bakFile);
        }

        await _safeReplaceFile(tmpFile, mainFile);
        _corruptUnrecovered = false;
        return true;
      } catch (e, st) {
        debugPrint('[StorageService.save] Error writing $_fileName: $e\n$st');
        return false;
      }
    });
    _writeQueue = op.then((_) {});
    return op;
  }

  Future<void> _safeReplaceFile(File source, File target) async {
    try {
      await source.rename(target.path);
    } on FileSystemException {
      if (target.existsSync()) {
        await target.delete();
      }
      await source.rename(target.path);
    }
  }
}
