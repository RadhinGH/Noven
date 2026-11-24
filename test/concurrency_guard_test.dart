import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noven/services/cover_cache_service.dart';
import 'package:noven/services/library_database.dart';
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
    tempDir = await Directory.systemTemp.createTemp('noven_concurrency_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  LocalMusicSource createSource({
    required LibraryDatabase db,
    Future<List<String>> Function()? pickFilesOverride,
    Future<Uri?> Function()? pickDirectoryOverride,
  }) {
    return LocalMusicSource(
      db: db,
      coverCache: CoverCacheService(directoryProvider: () async => tempDir),
      pickFilesOverride: pickFilesOverride,
      pickDirectoryOverride: pickDirectoryOverride,
    );
  }

  test('klik pickFiles berkali-kali saat file manager terbuka hanya buka 1 kali',
      () async {
    final db = LibraryDatabase(
      dbPathProvider: () async => p.join(tempDir.path, 'db1.sqlite'),
    );
    final firstDialog = Completer<List<String>>();
    var filePickerCalls = 0;

    final source = createSource(
      db: db,
      pickFilesOverride: () {
        filePickerCalls++;
        if (filePickerCalls == 1) return firstDialog.future;
        return Future.value(const <String>[]);
      },
    );

    final pending = <Future<int>>[
      source.pickFiles(),
      source.pickFiles(),
      source.pickFiles(),
      source.pickFiles(),
      source.pickFiles(),
    ];

    expect(source.isFilePickerBusy, isTrue);
    expect(filePickerCalls, 1);

    final songFile = File(p.join(tempDir.path, 'track.mp3'));
    await songFile.writeAsBytes([0x49, 0x44, 0x33]);
    firstDialog.complete([songFile.path]);

    final results = await Future.wait(pending);
    expect(results, [1, 0, 0, 0, 0]);
    expect(source.isFilePickerBusy, isFalse);

    // Setelah picker ditutup, panggilan berikutnya diperbolehkan kembali
    await source.pickFiles();
    expect(filePickerCalls, 2);

    await db.close();
  });

  test(
      'pickFolder, pickFiles, dan relocateTrack saling memblokir saat file manager aktif',
      () async {
    final db = LibraryDatabase(
      dbPathProvider: () async => p.join(tempDir.path, 'db2.sqlite'),
    );
    final dirDialog = Completer<Uri?>();
    var dirCalls = 0;
    var fileCalls = 0;

    final source = createSource(
      db: db,
      pickDirectoryOverride: () {
        dirCalls++;
        return dirDialog.future;
      },
      pickFilesOverride: () async {
        fileCalls++;
        return const <String>[];
      },
    );

    final folderFuture = source.pickFolder();
    final blockedFolder = source.pickFolder();
    final blockedFiles = source.pickFiles();
    final blockedRelocate = source.relocateTrack('some_id');

    expect(source.isFilePickerBusy, isTrue);
    expect(dirCalls, 1);
    expect(fileCalls, 0);

    dirDialog.complete(null);

    expect(await folderFuture, 0);
    expect(await blockedFolder, 0);
    expect(await blockedFiles, 0);
    expect(await blockedRelocate, isNull);
    expect(source.isFilePickerBusy, isFalse);

    await source.pickFiles();
    expect(fileCalls, 1);

    await db.close();
  });

  test('lock file manager tetap dilepas jika picker melempar exception',
      () async {
    final db = LibraryDatabase(
      dbPathProvider: () async => p.join(tempDir.path, 'db3.sqlite'),
    );
    var calls = 0;

    final source = createSource(
      db: db,
      pickFilesOverride: () async {
        calls++;
        if (calls == 1) {
          throw StateError('picker aborted');
        }
        return const <String>[];
      },
    );

    await expectLater(source.pickFiles(), throwsStateError);
    expect(source.isFilePickerBusy, isFalse);

    await expectLater(source.pickFiles(), completion(0));
    expect(calls, 2);

    await db.close();
  });
}
