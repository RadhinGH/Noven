import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_picker/file_picker.dart';

import '../models/track.dart';
import 'music_source.dart';

class LocalMusicSource extends MusicSource {
  static const _supportedExts = ['.mp3', '.flac', '.wav', '.ogg', '.opus'];

  final List<Track> _tracks = [];
  final Set<String> _savedFolders = {};
  final Set<String> _savedFiles = {};

  @override
  String get id => 'local';

  @override
  String get name => 'Local Storage';

  @override
  String get description => 'File MP3, FLAC, WAV, OGG dari perangkat kamu';

  List<String> get savedFolders => List.unmodifiable(_savedFolders);
  List<String> get savedFiles => List.unmodifiable(_savedFiles);

  @override
  Future<List<Track>> fetchTracks() async => List.unmodifiable(_tracks);

  /// Memilih satu atau banyak file audio lokal
  Future<int> pickFiles() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'flac', 'wav', 'ogg', 'opus'],
    );
    if (files.isEmpty) return 0;

    int added = 0;
    for (final file in files) {
      final path = file.path;
      if (path == null) continue;
      _savedFiles.add(path);
      if (_tracks.any((t) => t.id == path)) continue;
      _tracks.add(_createTrackFromPath(path));
      added++;
    }
    return added;
  }

  /// Scan 1 folder penuh (beserta subfolder di dalamnya)
  Future<int> pickFolder() async {
    final uri = await FilePicker.pickDirectory();
    if (uri == null) return 0;

    final folderPath = uri.toFilePath();
    _savedFolders.add(folderPath);
    return _scanFolder(folderPath);
  }

  /// Memulihkan daftar folder dan file lokal tersimpan saat startup
  Future<void> restoreFromSaved({
    required List<String> folders,
    required List<String> files,
  }) async {
    _tracks.clear();
    _savedFolders.clear();
    _savedFiles.clear();

    for (final folder in folders) {
      if (Directory(folder).existsSync()) {
        _savedFolders.add(folder);
        _scanFolder(folder);
      }
    }

    for (final filePath in files) {
      if (File(filePath).existsSync()) {
        _savedFiles.add(filePath);
        if (!_tracks.any((t) => t.id == filePath)) {
          _tracks.add(_createTrackFromPath(filePath));
        }
      }
    }
  }

  /// Scan ulang semua folder dan file yang tersimpan
  Future<int> rescanAll() async {
    final folders = List<String>.from(_savedFolders);
    final files = List<String>.from(_savedFiles);
    await restoreFromSaved(folders: folders, files: files);
    return _tracks.length;
  }

  /// Menghapus 1 folder tersimpan dan membangun ulang daftar lagu lokal
  Future<void> removeFolder(String folderPath) async {
    _savedFolders.remove(folderPath);
    await rescanAll();
  }

  int _scanFolder(String folderPath) {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return 0;

    final audioFiles = <File>[];
    _collectAudioFiles(dir, audioFiles);
    audioFiles.sort((a, b) => a.path.compareTo(b.path));

    int added = 0;
    for (final file in audioFiles) {
      if (_tracks.any((t) => t.id == file.path)) continue;
      _tracks.add(_createTrackFromPath(file.path));
      added++;
    }
    return added;
  }

  void _collectAudioFiles(Directory dir, List<File> out) {
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          final lower = entity.path.toLowerCase();
          if (_supportedExts.any((ext) => lower.endsWith(ext))) {
            out.add(entity);
          }
        } else if (entity is Directory) {
          _collectAudioFiles(entity, out);
        }
      }
    } on FileSystemException {
      // Lewati subfolder yang tidak dapat dibaca agar folder lain tetap terbaca
    }
  }

  Track _createTrackFromPath(String filePath) {
    final fileName = filePath.split(Platform.pathSeparator).last;
    final fallbackTitle = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    String title = fallbackTitle;
    String artist = 'Unknown Artist';
    String? album;
    Uint8List? coverBytes;
    Duration? duration;
    String? lyrics;

    try {
      final metadata = readMetadata(File(filePath), getImage: true);
      if (metadata.title != null && metadata.title!.trim().isNotEmpty) {
        title = metadata.title!.trim();
      }
      if (metadata.artist != null && metadata.artist!.trim().isNotEmpty) {
        artist = metadata.artist!.trim();
      }
      if (metadata.album != null && metadata.album!.trim().isNotEmpty) {
        album = metadata.album!.trim();
      }
      if (metadata.pictures.isNotEmpty) {
        coverBytes = metadata.pictures.first.bytes;
      }
      duration = metadata.duration;
      if (metadata.lyrics != null && metadata.lyrics!.trim().isNotEmpty) {
        lyrics = metadata.lyrics!.trim();
      }
    } catch (_) {}

    if (lyrics == null) {
      try {
        final lrcPath = filePath.replaceAll(RegExp(r'\.[^.]+$'), '.lrc');
        final lrcFile = File(lrcPath);
        if (lrcFile.existsSync()) {
          final lrcText = lrcFile.readAsStringSync().trim();
          if (lrcText.isNotEmpty) {
            lyrics = lrcText;
          }
        }
      } catch (_) {}
    }

    return Track(
      id: filePath,
      title: title,
      artist: artist,
      album: album,
      pathOrUrl: filePath,
      sourceType: TrackSourceType.local,
      coverBytes: coverBytes,
      duration: duration,
      lyrics: lyrics,
    );
  }
}
