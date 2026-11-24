import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Stores extracted album artwork on disk under `<appSupportDir>/covers`
/// instead of retaining `Uint8List` cover bytes in memory.
class CoverCacheService {
  final Future<Directory> Function() _directoryProvider;

  CoverCacheService({Future<Directory> Function()? directoryProvider})
      : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory;

  Future<Directory> _getCoversDir() async {
    final baseDir = await _directoryProvider();
    final coversDir = Directory(p.join(baseDir.path, 'covers'));
    if (!coversDir.existsSync()) {
      await coversDir.create(recursive: true);
    }
    return coversDir;
  }

  /// Saves artwork bytes atomically to disk and returns the file path.
  /// Identical artwork bytes map to the same content-hashed filename.
  Future<String?> saveCoverBytes(Uint8List bytes) async {
    if (bytes.isEmpty) return null;

    final coversDir = await _getCoversDir();
    final hash = _contentHash(bytes);
    final ext = _detectExtension(bytes);
    final targetPath = p.join(coversDir.path, '$hash$ext');
    final targetFile = File(targetPath);

    if (targetFile.existsSync() && targetFile.lengthSync() > 0) {
      return targetFile.path;
    }

    final tmpFile = File('$targetPath.tmp');
    await tmpFile.writeAsBytes(bytes, flush: true);
    await _safeReplace(tmpFile, targetFile);
    return targetFile.path;
  }

  /// Deletes [coverPath] only if it lives inside our covers cache directory
  /// and is no longer referenced by any track in the database.
  Future<void> deleteCoverIfUnreferenced(
    String? coverPath, {
    required bool isStillReferenced,
  }) async {
    if (coverPath == null || coverPath.trim().isEmpty || isStillReferenced) {
      return;
    }

    final coversDir = await _getCoversDir();
    final normalizedCoversDir = p.normalize(coversDir.path);
    final normalizedCover = p.normalize(coverPath);

    final isInsideCoversDir = Platform.isWindows
        ? p.isWithin(
            normalizedCoversDir.toLowerCase(),
            normalizedCover.toLowerCase(),
          )
        : p.isWithin(normalizedCoversDir, normalizedCover);

    if (!isInsideCoversDir) return;

    final file = File(normalizedCover);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  Future<void> _safeReplace(File source, File target) async {
    try {
      await source.rename(target.path);
    } on FileSystemException {
      if (target.existsSync()) {
        await target.delete();
      }
      await source.rename(target.path);
    }
  }

  String _contentHash(Uint8List bytes) {
    var fnv1 = 0x811c9dc5;
    var djb2 = 5381;
    for (final b in bytes) {
      fnv1 ^= b;
      fnv1 = (fnv1 * 0x01000193) & 0xffffffff;
      djb2 = (((djb2 << 5) + djb2) ^ b) & 0xffffffff;
    }
    final h1 = fnv1.toRadixString(16).padLeft(8, '0');
    final h2 = djb2.toRadixString(16).padLeft(8, '0');
    final len = bytes.length.toRadixString(16);
    return '$h1$h2$len';
  }

  String _detectExtension(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return '.gif';
    }
    return '.jpg';
  }
}
