import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../controllers/library_controller.dart';
import '../../models/track.dart';
import '../../services/android_media_service.dart';
import '../../sources/local_source.dart';
import '../theme/noven_colors.dart';
import '../widgets/album_detail_view.dart';
import '../widgets/audio_visualizer.dart';
import '../widgets/cover_art.dart';
import '../widgets/edit_track_dialog.dart';
import '../widgets/lyrics_panel.dart';
import '../widgets/nav_rail.dart';
import '../widgets/now_playing_card.dart';
import '../widgets/playlists_view.dart';
import '../widgets/queue_panel.dart';

class _AlbumGroup {
  final String name;
  final String artist;
  final List<Track> tracks;

  const _AlbumGroup({
    required this.name,
    required this.artist,
    required this.tracks,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final LibraryController _controller = LibraryController(
    onStatusMessage: _showStatusSnack,
  );

  int _selectedMenuIndex = 0; // 0 = Home, 1 = Library, 2 = Playlists, 3 = Sources
  String? _selectedAlbumName;
  String? _selectedMobilePlaylistId;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  bool _isSeeking = false;
  double _seekValueMs = 0;
  bool _isDraggingOver = false;
  bool _showFavoritesOnly = false;
  int _undoSnackToken = 0;

  bool get _isDesktopDropSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _controller.flushOnLifecyclePause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _showStatusSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: NovenColors.surface,
        duration: const Duration(seconds: 3),
        content: Text(message, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  void _showImportFeedback(ImportResult result) {
    if (result.isEmpty) return;
    _showStatusSnack(result.formatFeedback());
  }

  Future<void> _handleImportFiles() async {
    final result = await _controller.importFiles();
    if (!mounted) return;
    _showImportFeedback(result);
  }

  Future<void> _handleImportFolder() async {
    final result = await _controller.importFolder();
    if (!mounted) return;
    _showImportFeedback(result);
  }

  Future<void> _handleDroppedPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    final result = await _controller.importDroppedPaths(paths);
    if (!mounted) return;
    _showImportFeedback(result);
  }

  Future<bool> _showRationaleDialog({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: NovenColors.surface,
        title: Text(title),
        content: Text(
          body,
          style: TextStyle(color: NovenColors.silver.withValues(alpha: 0.9)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Nanti Saja'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return approved ?? false;
  }

  Future<void> _showOpenSettingsDialog({
    required String title,
    required String body,
  }) async {
    final open = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: NovenColors.surface,
        title: Text(title),
        content: Text(
          body,
          style: TextStyle(color: NovenColors.silver.withValues(alpha: 0.9)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Tutup'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            icon: const Icon(Icons.settings_rounded, size: 18),
            label: const Text('Buka Pengaturan'),
          ),
        ],
      ),
    );
    if (open == true) {
      await _controller.androidMedia.openAppSettings();
    }
  }

  Future<void> _handleScanAndroidAudio() async {
    if (_controller.isPickingFiles) return;

    var status = await _controller.androidMedia.checkAudioPermission();
    if (!mounted) return;

    if (status == AndroidPermissionStatus.unsupported) {
      await _handleImportFiles();
      return;
    }

    if (status == AndroidPermissionStatus.permanentlyDenied) {
      await _showOpenSettingsDialog(
        title: 'Izin Audio Ditolak Permanen',
        body:
            'Noven membutuhkan izin akses audio agar bisa memindai file MP3/FLAC di perangkat kamu. Buka Pengaturan Aplikasi -> Izin -> Musik & Audio lalu izinkan akses.',
      );
      return;
    }

    if (status == AndroidPermissionStatus.denied) {
      final agreed = await _showRationaleDialog(
        title: 'Izinkan Akses Musik Lokal',
        body:
            'Noven hanya membaca daftar & metadata lagu dari penyimpanan perangkatmu (tanpa menyalin ulang atau mengubah file asli).',
        confirmLabel: 'Lanjutkan',
      );
      if (!agreed || !mounted) return;

      status = await _controller.androidMedia.requestAudioPermission();
      if (!mounted) return;

      if (status == AndroidPermissionStatus.permanentlyDenied) {
        await _showOpenSettingsDialog(
          title: 'Izin Audio Ditolak Permanen',
          body:
              'Izin ditolak permanen oleh sistem. Aktifkan izin Musik & Audio di Pengaturan Aplikasi untuk memindai lagu di HP.',
        );
        return;
      }
      if (status != AndroidPermissionStatus.granted) {
        _showStatusSnack(
          'Izin akses audio diperlukan untuk memindai musik di perangkat.',
        );
        return;
      }
    }

    try {
      final result = await _controller.scanAndroidDeviceAudio();
      if (!mounted) return;
      _showStatusSnack(
        result.isEmpty
            ? 'Tidak ditemukan file musik baru di perangkat.'
            : result.formatFeedback(),
      );
    } catch (_) {
      if (!mounted) return;
      _showStatusSnack('Gagal memindai audio perangkat.');
    }
  }

  Future<void> _handleRequestAndroidNotifications() async {
    var status = await _controller.androidMedia.checkNotificationPermission();
    if (!mounted) return;

    if (status == AndroidPermissionStatus.granted) {
      _showStatusSnack('Izin notifikasi sudah aktif.');
      return;
    }
    if (status == AndroidPermissionStatus.unsupported) return;

    if (status == AndroidPermissionStatus.permanentlyDenied) {
      await _showOpenSettingsDialog(
        title: 'Izin Notifikasi Ditolak Permanen',
        body:
            'Aktifkan izin Notifikasi di Pengaturan Aplikasi agar kontrol pemutaran musik dapat tampil di panel notifikasi Android.',
      );
      return;
    }

    final agreed = await _showRationaleDialog(
      title: 'Izinkan Notifikasi Pemutar',
      body:
          'Digunakan untuk menampilkan status lagu dan kontrol pemutaran di panel notifikasi Android 13 ke atas.',
      confirmLabel: 'Izinkan',
    );
    if (!agreed || !mounted) return;

    status = await _controller.androidMedia.requestNotificationPermission();
    if (!mounted) return;
    if (status == AndroidPermissionStatus.granted) {
      _showStatusSnack('Izin notifikasi diaktifkan.');
    } else if (status == AndroidPermissionStatus.permanentlyDenied) {
      await _showOpenSettingsDialog(
        title: 'Izin Notifikasi Ditolak Permanen',
        body:
            'Aktifkan izin Notifikasi di Pengaturan Aplikasi agar kontrol notifikasi tersedia.',
      );
    }
  }

  Future<void> _handleRescanFolders() async {
    final result = await _controller.rescanLocalFolders();
    if (!mounted) return;
    final suffix = result.unavailable > 0
        ? ' (${result.unavailable} tidak tersedia)'
        : '';
    _showStatusSnack('Library lokal diperbarui: ${result.total} lagu$suffix.');
  }

  Future<void> _handleLocateTrack(Track track) async {
    final updated = await _controller.locateTrack(track);
    if (updated != null && mounted) {
      _showStatusSnack('"${updated.title}" berhasil dihubungkan ulang.');
    }
  }

  Future<void> _handleEditTrack(Track track) async {
    if (track.sourceType != TrackSourceType.local) return;
    final edited = await showEditTrackDialog(context, track);
    if (edited == null || !mounted) return;

    final updated = await _controller.editTrackMetadata(
      track.id,
      title: edited.title,
      artist: edited.artist,
      album: edited.album,
    );
    if (updated != null && mounted) {
      _showStatusSnack('Info "${updated.title}" diperbarui.');
    }
  }

  Future<void> _handleToggleFavorite(Track track) async {
    final updated = await _controller.toggleFavorite(track);
    if (updated != null && mounted) {
      _showStatusSnack(
        updated.isFavorite
            ? '"${updated.title}" ditambahkan ke Favorit.'
            : '"${updated.title}" dihapus dari Favorit.',
      );
    }
  }

  Future<void> _handleRemoveTracks(List<String> trackIds) async {
    final result = await _controller.removeTracksFromLibrary(trackIds);
    if (result == null || !mounted) return;
    _showUndoRemoveSnackBar(result);
  }

  void _showUndoRemoveSnackBar(RemoveTracksResult result) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final token = ++_undoSnackToken;
    messenger.clearSnackBars();

    final controller = messenger.showSnackBar(
      SnackBar(
        backgroundColor: NovenColors.surface,
        duration: const Duration(seconds: 5),
        content: Text(
          result.message,
          style: const TextStyle(color: Colors.white),
        ),
        action: SnackBarAction(
          label: 'Undo',
          textColor: NovenColors.accentLight,
          onPressed: () {
            unawaited(_controller.undoLastRemove());
          },
        ),
      ),
    );

    controller.closed.then((reason) {
      if (token == _undoSnackToken &&
          reason != SnackBarClosedReason.action) {
        unawaited(_controller.discardPendingUndo());
      }
    });
  }

  Future<void> _showAddUrlDialog() async {
    final result = await showDialog<({String title, String artist, String url})>(
      context: context,
      builder: (_) => const _AddUrlDialog(),
    );

    if (result == null || result.url.trim().isEmpty) return;
    final added = await _controller.addCustomUrl(
      title: result.title,
      artist: result.artist,
      url: result.url,
    );
    if (!mounted) return;
    _showStatusSnack(
      added
          ? 'URL stream ditambahkan.'
          : 'URL stream sudah ada atau tidak valid.',
    );
  }

  Future<void> _promptAddTrackToPlaylist(Track track) {
    return showAddToPlaylistDialog(
      context: context,
      track: track,
      playlists: _controller.playlists,
      onAddToExisting: (playlist) {
        _controller.addTracksToPlaylist(playlist.id, [track.id]);
        _showStatusSnack('"${track.title}" ditambahkan ke "${playlist.name}".');
      },
      onCreateAndAdd: (newName) {
        _controller.createPlaylist(newName, initialTrackIds: [track.id]);
      },
    );
  }

  Future<void> _openQueueSheet() {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: NovenColors.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return ListenableBuilder(
          listenable: _controller,
          builder: (_, _) => SafeArea(
            child: SizedBox(
              height: MediaQuery.of(sheetCtx).size.height * 0.65,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: QueuePanel(
                  playQueue: _controller.playQueue,
                  allTracks: _controller.allTracks,
                  currentTrackId: _controller.currentTrack?.id,
                  showModeSwitcher: false,
                  onPlayFromQueue: (track) {
                    Navigator.of(sheetCtx).pop();
                    _controller.playTrack(track, _controller.playQueue);
                  },
                  onPlayFromAllTracks: (track, list) {
                    Navigator.of(sheetCtx).pop();
                    _controller.playTrack(track, list, resetShuffleCycle: true);
                  },
                  onReorderQueue: _controller.reorderQueue,
                  onRemoveFromQueue: _controller.removeFromQueue,
                  onClearQueue: _controller.clearQueue,
                  onPlayNext: _controller.insertPlayNext,
                  onAddToQueue: _controller.addToQueue,
                  onAddToPlaylist: _promptAddTrackToPlaylist,
                  onToggleFavorite: _handleToggleFavorite,
                  onEditTrack: _handleEditTrack,
                  onRemoveTrack: (track) => _handleRemoveTracks([track.id]),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _folderDisplayName(String folderPath) {
    final parts = folderPath
        .split(Platform.pathSeparator)
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? folderPath : parts.last;
  }

  String _greetingText() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  List<_AlbumGroup> _groupAlbums(List<Track> tracks) {
    final map = <String, List<Track>>{};
    for (final t in tracks) {
      final key = (t.album != null && t.album!.trim().isNotEmpty)
          ? t.album!.trim()
          : t.title;
      map.putIfAbsent(key, () => []).add(t);
    }
    return map.entries
        .map(
          (e) => _AlbumGroup(
            name: e.key,
            artist: e.value.first.artist,
            tracks: e.value,
          ),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final canExitApp = !_controller.isSelectionMode &&
            _selectedAlbumName == null &&
            _selectedMobilePlaylistId == null &&
            _selectedMenuIndex == 0;

        final scaffold = LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= 860;
            final isTallEnough = constraints.maxHeight >= 560;

            return PopScope(
              canPop: canExitApp,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) return;
                if (_controller.isSelectionMode) {
                  _controller.exitSelectionMode();
                  return;
                }
                if (_selectedAlbumName != null) {
                  setState(() => _selectedAlbumName = null);
                  return;
                }
                if (_selectedMobilePlaylistId != null) {
                  setState(() => _selectedMobilePlaylistId = null);
                  return;
                }
                if (_selectedMenuIndex != 0) {
                  setState(() => _selectedMenuIndex = 0);
                }
              },
              child: Scaffold(
                backgroundColor: NovenColors.bg,
                body: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      if (isDesktop)
                        NovenNavRail(
                          selectedIndex: _selectedMenuIndex,
                          onSelect: (i) => setState(() {
                            _selectedMenuIndex = i;
                            _selectedAlbumName = null;
                          }),
                          onImportFolder: _controller.isAndroid
                              ? _handleScanAndroidAudio
                              : _handleImportFolder,
                          onImportFiles: _handleImportFiles,
                          onAddUrl: _showAddUrlDialog,
                        ),
                      Expanded(
                        child: _buildActivePage(
                          isDesktop: isDesktop,
                          isTallEnough: isTallEnough,
                        ),
                      ),
                    ],
                  ),
                ),
                bottomNavigationBar: isDesktop
                    ? null
                    : NavigationBar(
                        selectedIndex: _selectedMenuIndex,
                        backgroundColor: NovenColors.surface,
                        indicatorColor: NovenColors.accent.withValues(
                          alpha: 0.35,
                        ),
                        onDestinationSelected: (index) {
                          setState(() {
                            _selectedMenuIndex = index;
                            _selectedAlbumName = null;
                            if (index != 2) {
                              _selectedMobilePlaylistId = null;
                            }
                          });
                        },
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.home_rounded),
                            label: 'Home',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.library_music_rounded),
                            label: 'Library',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.queue_music_rounded),
                            label: 'Playlists',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.hub_rounded),
                            label: 'Sources',
                          ),
                        ],
                      ),
              ),
            );
          },
        );

        if (!_isDesktopDropSupported) {
          return scaffold;
        }

        return DropTarget(
          enable: true,
          onDragEntered: (_) => setState(() => _isDraggingOver = true),
          onDragExited: (_) => setState(() => _isDraggingOver = false),
          onDragDone: (details) {
            setState(() => _isDraggingOver = false);
            final paths = details.files
                .map((item) => item.path)
                .where((path) => path.trim().isNotEmpty)
                .toList();
            unawaited(_handleDroppedPaths(paths));
          },
          child: Stack(
            children: [
              scaffold,
              if (_isDraggingOver)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      color: NovenColors.bg.withValues(alpha: 0.82),
                      alignment: Alignment.center,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 24,
                        ),
                        decoration: BoxDecoration(
                          color: NovenColors.surface,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: NovenColors.accentLight,
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: NovenColors.accent.withValues(alpha: 0.45),
                              blurRadius: 28,
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.library_add_rounded,
                              size: 48,
                              color: NovenColors.accentLight,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Lepas file atau folder audio di sini',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Mendukung MP3, FLAC, WAV, OGG, OPUS — duplikat dilewati otomatis',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: NovenColors.silver.withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActivePage({
    required bool isDesktop,
    required bool isTallEnough,
  }) {
    switch (_selectedMenuIndex) {
      case 0:
        return _buildHomeTab(isDesktop: isDesktop, isTallEnough: isTallEnough);
      case 1:
        return _buildLibraryTab(isDesktop: isDesktop);
      case 2:
        return _buildPlaylistsTab(isDesktop: isDesktop);
      default:
        return _buildSourcesTab(isDesktop: isDesktop);
    }
  }

  // ==================== TAB 0: HOME (KONSEP A TWEAKED) ====================
  Widget _buildHomeTab({
    required bool isDesktop,
    required bool isTallEnough,
  }) {
    final allTracks = _controller.allTracks;
    final currentTrack = _controller.currentTrack;
    final playQueue = _controller.playQueue;
    final query = _searchQuery.toLowerCase();
    final visibleTracks = query.isEmpty
        ? allTracks
        : allTracks.where((t) {
            return t.title.toLowerCase().contains(query) ||
                t.artist.toLowerCase().contains(query) ||
                (t.album?.toLowerCase().contains(query) ?? false);
          }).toList();
    final albums = _groupAlbums(visibleTracks);

    _AlbumGroup? selectedAlbum;
    if (_selectedAlbumName != null) {
      for (final a in _groupAlbums(allTracks)) {
        if (a.name == _selectedAlbumName) {
          selectedAlbum = a;
          break;
        }
      }
      if (selectedAlbum == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedAlbumName != null) {
            setState(() => _selectedAlbumName = null);
          }
        });
      }
    }

    if (selectedAlbum != null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          isDesktop ? 26 : 16,
          isDesktop ? 20 : 14,
          isDesktop ? 26 : 16,
          isDesktop ? 20 : 12,
        ),
        child: Column(
          children: [
            Expanded(
              child: AlbumDetailView(
                albumName: selectedAlbum.name,
                artist: selectedAlbum.artist,
                tracks: selectedAlbum.tracks,
                currentTrackId: currentTrack?.id,
                isPlaying: _controller.engine.isPlaying,
                onBack: () => setState(() => _selectedAlbumName = null),
                onPlayTrack: (track, queue) => _controller.playTrack(
                  track,
                  queue,
                  resetShuffleCycle: true,
                ),
                onShuffleAlbum: _controller.shuffleTracks,
                onAddAlbumToQueue: _controller.addAlbumToQueue,
                onPlayNext: _controller.insertPlayNext,
                onAddToQueue: _controller.addToQueue,
                onAddToPlaylist: _promptAddTrackToPlaylist,
                onToggleFavorite: _handleToggleFavorite,
                onEditTrack: _handleEditTrack,
                onRemoveTrack: (track) => _handleRemoveTracks([track.id]),
              ),
            ),
            const SizedBox(height: 12),
            _buildNowPlayingCard(),
          ],
        ),
      );
    }

    final isFetchingCurrentLyrics = currentTrack != null &&
        _controller.fetchingLyricsTrackId == currentTrack.id;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 14,
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 12,
      ),
      child: Column(
        children: [
          _buildTopHeader(isDesktop: isDesktop),
          const SizedBox(height: 18),
          Expanded(
            child: (isDesktop && isTallEnough)
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Kolom Kiri: Hero Banner + Your Albums + Now Playing Card
                      Expanded(
                        flex: 13,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildHeroBanner(),
                            const SizedBox(height: 16),
                            _buildAlbumsSection(albums),
                            const Spacer(),
                            const SizedBox(height: 12),
                            _buildNowPlayingCard(),
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),

                      // Kolom Kanan: Queue/All Tracks + Lyrics / Album Cover Card
                      Expanded(
                        flex: 8,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 4,
                              child: QueuePanel(
                                playQueue: playQueue,
                                allTracks: visibleTracks,
                                currentTrackId: currentTrack?.id,
                                isSearchActive: _searchQuery.trim().isNotEmpty,
                                initialShowQueue: playQueue.isNotEmpty,
                                onPlayFromQueue: (track) =>
                                    _controller.playTrack(track, playQueue),
                                onPlayFromAllTracks: (track, list) =>
                                    _controller.playTrack(
                                      track,
                                      list,
                                      resetShuffleCycle: true,
                                    ),
                                onReorderQueue: _controller.reorderQueue,
                                onRemoveFromQueue: _controller.removeFromQueue,
                                onClearQueue: _controller.clearQueue,
                                onPlayNext: _controller.insertPlayNext,
                                onAddToQueue: _controller.addToQueue,
                                onAddToPlaylist: _promptAddTrackToPlaylist,
                                onToggleFavorite: _handleToggleFavorite,
                                onEditTrack: _handleEditTrack,
                                onRemoveTrack: (track) =>
                                    _handleRemoveTracks([track.id]),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              flex: 6,
                              child: LyricsPanel(
                                track: currentTrack,
                                positionListenable:
                                    _controller.engine.positionNotifier,
                                onSeek: _controller.engine.seek,
                                isFetching: isFetchingCurrentLyrics,
                                onRefreshLyrics: currentTrack == null
                                    ? null
                                    : () => _controller.ensureLyricsForTrack(
                                        currentTrack,
                                        forceRefresh: true,
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildHeroBanner(),
                              const SizedBox(height: 14),
                              _buildAlbumsSection(albums),
                              const SizedBox(height: 14),
                              SizedBox(
                                height: 220,
                                child: QueuePanel(
                                  playQueue: playQueue,
                                  allTracks: visibleTracks,
                                  currentTrackId: currentTrack?.id,
                                  isSearchActive:
                                      _searchQuery.trim().isNotEmpty,
                                  initialShowQueue: playQueue.isNotEmpty,
                                  onPlayFromQueue: (track) =>
                                      _controller.playTrack(track, playQueue),
                                  onPlayFromAllTracks: (track, list) =>
                                      _controller.playTrack(
                                        track,
                                        list,
                                        resetShuffleCycle: true,
                                      ),
                                  onReorderQueue: _controller.reorderQueue,
                                  onRemoveFromQueue:
                                      _controller.removeFromQueue,
                                  onClearQueue: _controller.clearQueue,
                                  onPlayNext: _controller.insertPlayNext,
                                  onAddToQueue: _controller.addToQueue,
                                  onAddToPlaylist: _promptAddTrackToPlaylist,
                                  onToggleFavorite: _handleToggleFavorite,
                                  onEditTrack: _handleEditTrack,
                                  onRemoveTrack: (track) =>
                                      _handleRemoveTracks([track.id]),
                                ),
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                height: 250,
                                child: LyricsPanel(
                                  track: currentTrack,
                                  positionListenable:
                                      _controller.engine.positionNotifier,
                                  onSeek: _controller.engine.seek,
                                  isFetching: isFetchingCurrentLyrics,
                                  onRefreshLyrics: currentTrack == null
                                      ? null
                                      : () => _controller.ensureLyricsForTrack(
                                          currentTrack,
                                          forceRefresh: true,
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _buildNowPlayingCard(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopHeader({required bool isDesktop}) {
    final searchField = Container(
      width: isDesktop ? 300 : double.infinity,
      height: 40,
      decoration: BoxDecoration(
        color: NovenColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (val) => setState(() => _searchQuery = val),
        style: const TextStyle(fontSize: 13.5, color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Search',
          hintStyle: TextStyle(
            fontSize: 13.5,
            color: NovenColors.silver.withValues(alpha: 0.55),
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 18,
            color: NovenColors.silver.withValues(alpha: 0.65),
          ),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: NovenColors.silver,
                  ),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );

    final greeting = RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(fontSize: isDesktop ? 20 : 18),
        children: [
          TextSpan(
            text: '${_greetingText()}, ',
            style: TextStyle(
              color: NovenColors.silver.withValues(alpha: 0.8),
              fontWeight: FontWeight.w400,
            ),
          ),
          const TextSpan(
            text: 'Noven',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );

    if (!isDesktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: greeting),
              IconButton(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                tooltip: _controller.isAndroid
                    ? 'Scan Musik HP'
                    : 'Import Folder',
                icon: Icon(
                  _controller.isAndroid
                      ? Icons.library_music_rounded
                      : Icons.folder_open_rounded,
                  color: NovenColors.silver,
                ),
                onPressed: _controller.isPickingFiles
                    ? null
                    : (_controller.isAndroid
                          ? _handleScanAndroidAudio
                          : _handleImportFolder),
              ),
              IconButton(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                tooltip: 'Tambah Lagu',
                icon: const Icon(Icons.add_rounded, color: NovenColors.silver),
                onPressed: _controller.isPickingFiles
                    ? null
                    : _handleImportFiles,
              ),
            ],
          ),
          const SizedBox(height: 10),
          searchField,
        ],
      );
    }

    return Row(
      children: [
        greeting,
        const Spacer(),
        searchField,
      ],
    );
  }

  Widget _buildHeroBanner() {
    final track = _controller.currentTrack ??
        (_controller.allTracks.isNotEmpty ? _controller.allTracks.first : null);
    final isOnline = track?.sourceType == TrackSourceType.stream;

    return Container(
      height: 190,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            NovenColors.accent,
            Color(0xFF473C78),
            NovenColors.surface,
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: NovenColors.accent.withValues(alpha: 0.25),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            // Artwork kanan pudar halus ke kiri
            if ((track?.coverPath != null && track!.coverPath!.isNotEmpty) ||
                (track?.coverUrl != null && track!.coverUrl!.isNotEmpty))
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 240,
                child: ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Colors.transparent, Colors.black],
                  ).createShader(rect),
                  blendMode: BlendMode.dstIn,
                  child: Opacity(
                    opacity: 0.55,
                    child:
                        track.coverPath != null && track.coverPath!.isNotEmpty
                        ? Image.file(
                            File(track.coverPath!),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          )
                        : Image.network(
                            track.coverUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                  ),
                ),
              )
            else
              Positioned(
                right: -30,
                top: -30,
                child: Container(
                  width: 190,
                  height: 190,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        NovenColors.silver.withValues(alpha: 0.22),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),

            // Konten Hero + Real-Time FFT Visualizer
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _controller.currentTrack != null
                              ? 'Now Playing'
                              : 'Featured',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (track != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: NovenColors.bg.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isOnline
                                    ? Icons.cloud_rounded
                                    : Icons.graphic_eq_rounded,
                                size: 12,
                                color: NovenColors.silver,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isOnline ? 'Stream' : 'Local Audio',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: NovenColors.silver,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    track?.title ?? 'Welcome to Noven',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    track != null
                        ? '${track.artist}${track.album != null ? ' • ${track.album}' : ''}'
                        : 'Import your local music folder or stream online tracks',
                    style: TextStyle(
                      fontSize: 13,
                      color: NovenColors.silver.withValues(alpha: 0.9),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  AudioVisualizer(
                    fftListenable: _controller.engine.fftNotifier,
                    primaryColor: NovenColors.accentLight,
                    secondaryColor: NovenColors.silver,
                    barCount: 44,
                    height: 52,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumsSection(List<_AlbumGroup> albums) {
    final currentTrack = _controller.currentTrack;
    final currentAlbumKey = currentTrack == null
        ? null
        : ((currentTrack.album != null &&
                  currentTrack.album!.trim().isNotEmpty)
              ? currentTrack.album!.trim()
              : currentTrack.title);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Your Albums',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => _selectedMenuIndex = 1),
              child: Text(
                'See All',
                style: TextStyle(
                  fontSize: 12.5,
                  color: NovenColors.silver.withValues(alpha: 0.75),
                ),
              ),
            ),
          ],
        ),
        SizedBox(
          height: 152,
          child: albums.isEmpty
              ? Center(
                  child: Text(
                    'Belum ada album — klik + atau drag & drop folder musik ke sini',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: NovenColors.silver.withValues(alpha: 0.6),
                    ),
                  ),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 6,
                  ),
                  itemCount: albums.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 16),
                  itemBuilder: (context, index) {
                    final album = albums[index];
                    final isFeatured = currentAlbumKey != null
                        ? album.name == currentAlbumKey
                        : index == 0;

                    final card = GestureDetector(
                      onTap: () =>
                          setState(() => _selectedAlbumName = album.name),
                      child: Container(
                        width: 136,
                        height: 136,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: NovenColors.surface,
                          border: Border.all(
                            color: isFeatured
                                ? NovenColors.accentLight.withValues(alpha: 0.7)
                                : Colors.white.withValues(alpha: 0.08),
                            width: isFeatured ? 1.5 : 1,
                          ),
                          boxShadow: isFeatured
                              ? [
                                  BoxShadow(
                                    color: NovenColors.accent.withValues(
                                      alpha: 0.55,
                                    ),
                                    blurRadius: 20,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(19),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CoverArt(
                                track: album.tracks.first,
                                size: 136,
                                radius: 19,
                              ),
                              // Scrim gelap bawah agar teks album terbaca jelas
                              Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black.withValues(alpha: 0.82),
                                    ],
                                  ),
                                ),
                              ),
                              if (isFeatured)
                                Positioned(
                                  top: 8,
                                  right: 8,
                                  child: Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: NovenColors.accent,
                                      boxShadow: [
                                        BoxShadow(
                                          color: NovenColors.accent.withValues(
                                            alpha: 0.65,
                                          ),
                                          blurRadius: 10,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              Positioned(
                                left: 10,
                                right: 10,
                                bottom: 10,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      album.name,
                                      style: const TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${album.artist} • ${album.tracks.length} track',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: NovenColors.silver.withValues(
                                          alpha: 0.85,
                                        ),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );

                    return isFeatured
                        ? Transform.rotate(angle: -0.055, child: card)
                        : card;
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildNowPlayingCard() {
    final engine = _controller.engine;
    return NowPlayingCard(
      track: _controller.currentTrack,
      isPlaying: engine.isPlaying,
      isLoading: _controller.isLoadingTrack,
      positionListenable: engine.positionNotifier,
      duration: engine.duration,
      isSeeking: _isSeeking,
      seekValueMs: _seekValueMs,
      volume: engine.volume,
      isMuted: engine.isMuted,
      isShuffle: _controller.shuffle,
      repeatMode: _controller.repeatMode,
      onTogglePlay: _controller.togglePlayPause,
      onPrev: _controller.playPrevious,
      onNext: _controller.playNext,
      onToggleShuffle: _controller.toggleShuffle,
      onCycleRepeat: _controller.cycleRepeatMode,
      onSeekStart: (value) {
        setState(() {
          _isSeeking = true;
          _seekValueMs = value;
        });
      },
      onSeekChange: (value) {
        setState(() => _seekValueMs = value);
      },
      onSeekEnd: (value) {
        _controller.seekToMs(value);
        setState(() => _isSeeking = false);
      },
      onVolumeChange: _controller.setVolume,
      onVolumeChangeEnd: (_) => _controller.onVolumeChangeEnd(),
      onToggleMute: _controller.toggleMute,
      onOpenQueue: _openQueueSheet,
      queueCount: _controller.playQueue.length,
    );
  }

  // ==================== TAB 1: LIBRARY (LOKAL) ====================
  Widget _buildLibraryTab({required bool isDesktop}) {
    final allLocals = _controller.localTracks;
    final favCount = allLocals.where((t) => t.isFavorite).length;
    final visibleLocals = _showFavoritesOnly
        ? allLocals.where((t) => t.isFavorite).toList()
        : allLocals;
    final isSelectionMode = _controller.isSelectionMode;
    final selectedIds = _controller.selectedTrackIds;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 14,
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Library',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '${allLocals.length} lagu lokal tersimpan',
                      style: TextStyle(
                        fontSize: 13,
                        color: NovenColors.silver.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    if (allLocals.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () {
                          if (isSelectionMode) {
                            _controller.exitSelectionMode();
                          } else {
                            _controller.enterSelectionMode();
                          }
                        },
                        icon: Icon(
                          isSelectionMode
                              ? Icons.close_rounded
                              : Icons.checklist_rounded,
                        ),
                        label: Text(isSelectionMode ? 'Batal Pilih' : 'Pilih'),
                      ),
                    OutlinedButton.icon(
                      onPressed: _controller.isPickingFiles
                          ? null
                          : (_controller.isAndroid
                                ? _handleScanAndroidAudio
                                : _handleImportFolder),
                      icon: Icon(
                        _controller.isAndroid
                            ? Icons.manage_search_rounded
                            : Icons.folder_open_rounded,
                      ),
                      label: Text(
                        _controller.isAndroid
                            ? 'Scan Musik HP'
                            : 'Import Folder',
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _controller.isPickingFiles
                          ? null
                          : _handleImportFiles,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Tambah Lagu'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (allLocals.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ChoiceChip(
                  label: Text('Semua (${allLocals.length})'),
                  selected: !_showFavoritesOnly,
                  selectedColor: NovenColors.accent,
                  backgroundColor: NovenColors.surface,
                  labelStyle: const TextStyle(color: Colors.white, fontSize: 12),
                  onSelected: (_) => setState(() => _showFavoritesOnly = false),
                ),
                ChoiceChip(
                  avatar: const Icon(
                    Icons.favorite_rounded,
                    size: 15,
                    color: Colors.pinkAccent,
                  ),
                  label: Text('Favorit ($favCount)'),
                  selected: _showFavoritesOnly,
                  selectedColor: NovenColors.accent,
                  backgroundColor: NovenColors.surface,
                  labelStyle: const TextStyle(color: Colors.white, fontSize: 12),
                  onSelected: (_) => setState(() => _showFavoritesOnly = true),
                ),
              ],
            ),
          ],
          if (isSelectionMode) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: NovenColors.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: NovenColors.accentLight.withValues(alpha: 0.45),
                ),
              ),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  Text(
                    '${selectedIds.length} dipilih',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      TextButton(
                        onPressed: () =>
                            _controller.selectAllTracks(visibleLocals),
                        child: const Text('Pilih Semua'),
                      ),
                      FilledButton.icon(
                        onPressed: selectedIds.isEmpty
                            ? null
                            : () => _handleRemoveTracks(selectedIds.toList()),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                        label: Text('Hapus (${selectedIds.length})'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          Expanded(
            child: visibleLocals.isEmpty
                ? Center(
                    child: Text(
                      _showFavoritesOnly
                          ? 'Belum ada lagu favorit.\nKlik menu ⋮ di lagu -> Favorit.'
                          : 'Belum ada lagu lokal.\nKlik "Import Folder" atau drag & drop folder/file audio ke jendela ini.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: NovenColors.silver.withValues(alpha: 0.7),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: visibleLocals.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final track = visibleLocals[index];
                      final isCurrent = _controller.currentTrack?.id == track.id;
                      final isSelected = selectedIds.contains(track.id);

                      return Opacity(
                        opacity: track.isAvailable ? 1.0 : 0.62,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onLongPress: () =>
                              _controller.enterSelectionMode(track.id),
                          onTap: () {
                            if (isSelectionMode) {
                              _controller.toggleTrackSelection(track.id);
                              return;
                            }
                            _controller.playTrack(
                              track,
                              visibleLocals.where((t) => t.isAvailable).toList(),
                              resetShuffleCycle: true,
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? NovenColors.accent.withValues(alpha: 0.28)
                                  : isCurrent
                                  ? NovenColors.accent.withValues(alpha: 0.22)
                                  : NovenColors.surface,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isSelected
                                    ? NovenColors.accentLight
                                    : !track.isAvailable
                                    ? Colors.amber.withValues(alpha: 0.45)
                                    : isCurrent
                                    ? NovenColors.accentLight.withValues(
                                        alpha: 0.7,
                                      )
                                    : Colors.white.withValues(alpha: 0.05),
                              ),
                            ),
                            child: Row(
                              children: [
                                if (isSelectionMode) ...[
                                  Checkbox(
                                    value: isSelected,
                                    activeColor: NovenColors.accent,
                                    onChanged: (_) => _controller
                                        .toggleTrackSelection(track.id),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                CoverArt(track: track, size: 44, radius: 10),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        track.title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        track.album != null
                                            ? '${track.artist} • ${track.album}'
                                            : track.artist,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: NovenColors.silver.withValues(
                                            alpha: 0.75,
                                          ),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                if (!track.isAvailable)
                                  Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.amber.withValues(
                                        alpha: 0.16,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: Colors.amber.withValues(
                                          alpha: 0.45,
                                        ),
                                      ),
                                    ),
                                    child: const Text(
                                      'Tidak tersedia',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.amberAccent,
                                      ),
                                    ),
                                  ),
                                if (track.isFavorite)
                                  const Padding(
                                    padding: EdgeInsets.only(right: 8),
                                    child: Icon(
                                      Icons.favorite_rounded,
                                      size: 16,
                                      color: Colors.pinkAccent,
                                    ),
                                  ),
                                if (track.isAvailable && track.lyrics != null)
                                  const Padding(
                                    padding: EdgeInsets.only(right: 10),
                                    child: Icon(
                                      Icons.lyrics_rounded,
                                      size: 16,
                                      color: NovenColors.accentLight,
                                    ),
                                  ),
                                if (track.duration != null)
                                  Text(
                                    _formatDuration(track.duration!),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: NovenColors.silver.withValues(
                                        alpha: 0.75,
                                      ),
                                    ),
                                  ),
                                PopupMenuButton<String>(
                                  tooltip: 'Opsi Lagu',
                                  icon: Icon(
                                    Icons.more_vert_rounded,
                                    size: 18,
                                    color: NovenColors.silver.withValues(
                                      alpha: 0.75,
                                    ),
                                  ),
                                  color: NovenColors.surface,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: 0.08,
                                      ),
                                    ),
                                  ),
                                  onSelected: (value) {
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          if (!mounted) return;
                                          switch (value) {
                                            case 'locate':
                                              _handleLocateTrack(track);
                                            case 'next':
                                              _controller.insertPlayNext(track);
                                            case 'queue':
                                              _controller.addToQueue(track);
                                            case 'playlist':
                                              _promptAddTrackToPlaylist(track);
                                            case 'favorite':
                                              _handleToggleFavorite(track);
                                            case 'edit':
                                              _handleEditTrack(track);
                                            case 'remove':
                                              _handleRemoveTracks([track.id]);
                                          }
                                        });
                                  },
                                  itemBuilder: (_) => track.isAvailable
                                      ? [
                                          const PopupMenuItem(
                                            value: 'next',
                                            child: Text('Play Next'),
                                          ),
                                          const PopupMenuItem(
                                            value: 'queue',
                                            child: Text('Add to Queue'),
                                          ),
                                          const PopupMenuItem(
                                            value: 'playlist',
                                            child: Text('Add to Playlist'),
                                          ),
                                          PopupMenuItem(
                                            value: 'favorite',
                                            child: Text(
                                              track.isFavorite
                                                  ? 'Hapus dari Favorit'
                                                  : 'Favorit',
                                            ),
                                          ),
                                          const PopupMenuItem(
                                            value: 'edit',
                                            child: Text('Edit Info'),
                                          ),
                                          const PopupMenuItem(
                                            value: 'remove',
                                            child: Text('Hapus dari Library'),
                                          ),
                                        ]
                                      : [
                                          const PopupMenuItem(
                                            value: 'locate',
                                            child: Text('Locate ulang'),
                                          ),
                                          PopupMenuItem(
                                            value: 'favorite',
                                            child: Text(
                                              track.isFavorite
                                                  ? 'Hapus dari Favorit'
                                                  : 'Favorit',
                                            ),
                                          ),
                                          const PopupMenuItem(
                                            value: 'edit',
                                            child: Text('Edit Info'),
                                          ),
                                          const PopupMenuItem(
                                            value: 'remove',
                                            child: Text('Hapus dari Library'),
                                          ),
                                        ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          _buildNowPlayingCard(),
        ],
      ),
    );
  }

  // ==================== TAB 2: PLAYLISTS ====================
  Widget _buildPlaylistsTab({required bool isDesktop}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 14,
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 12,
      ),
      child: Column(
        children: [
          Expanded(
            child: PlaylistsView(
              playlists: _controller.playlists,
              allTracks: _controller.allKnownTracks,
              currentTrackId: _controller.currentTrack?.id,
              isDesktop: isDesktop,
              selectedPlaylistId: isDesktop ? null : _selectedMobilePlaylistId,
              onSelectedPlaylistChanged: (id) {
                if (!isDesktop && _selectedMobilePlaylistId != id) {
                  setState(() => _selectedMobilePlaylistId = id);
                }
              },
              onCreatePlaylist: (name) => _controller.createPlaylist(name),
              onRenamePlaylist: _controller.renamePlaylist,
              onDeletePlaylist: _controller.deletePlaylist,
              onAddTracksToPlaylist: _controller.addTracksToPlaylist,
              onRemoveTrackFromPlaylist: _controller.removeTrackFromPlaylist,
              onReorderPlaylistTrack: _controller.reorderPlaylistTrack,
              onPlayTrack: (track, queue) => _controller.playTrack(
                track,
                queue,
                resetShuffleCycle: true,
              ),
              onShufflePlaylist: _controller.shuffleTracks,
              onLocateTrack: _handleLocateTrack,
              onRemoveTrackFromLibrary: (track) =>
                  _handleRemoveTracks([track.id]),
            ),
          ),
          const SizedBox(height: 12),
          _buildNowPlayingCard(),
        ],
      ),
    );
  }

  // ==================== TAB 3: SOURCES (PUSAT AGGREGATOR) ====================
  Widget _buildSourcesTab({required bool isDesktop}) {
    final sources = _controller.sources;
    final watchedFolders = _controller.watchedFolders;
    final localTracks = _controller.localTracks;
    final customStreams = _controller.customStreams;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 14,
        isDesktop ? 26 : 16,
        isDesktop ? 20 : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Music Sources',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Aktifkan atau nonaktifkan sumber musik yang ingin digabungkan ke beranda Noven.',
            style: TextStyle(color: NovenColors.silver.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: ListView.separated(
              itemCount: sources.length,
              separatorBuilder: (_, _) => const SizedBox(height: 14),
              itemBuilder: (context, index) {
                final source = sources[index];
                final isLocal = source.id == 'local';

                return Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: NovenColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: source.isEnabled
                          ? NovenColors.accentLight.withValues(alpha: 0.45)
                          : Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isLocal
                                ? Icons.folder_special_rounded
                                : Icons.cloud_queue_rounded,
                            color: source.isEnabled
                                ? NovenColors.accentLight
                                : NovenColors.silver.withValues(alpha: 0.45),
                            size: 28,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  source.name,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                                Text(
                                  source.description,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: NovenColors.silver.withValues(
                                      alpha: 0.75,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: source.isEnabled,
                            activeTrackColor: NovenColors.accent,
                            onChanged: (val) =>
                                _controller.setSourceEnabled(source, val),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: isLocal
                            ? [
                                OutlinedButton.icon(
                                  onPressed: _controller.isPickingFiles
                                      ? null
                                      : (_controller.isAndroid
                                            ? _handleScanAndroidAudio
                                            : _handleImportFolder),
                                  icon: Icon(
                                    _controller.isAndroid
                                        ? Icons.manage_search_rounded
                                        : Icons.folder_open_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    _controller.isAndroid
                                        ? 'Scan Musik HP'
                                        : 'Import Folder',
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _controller.isPickingFiles
                                      ? null
                                      : _handleImportFiles,
                                  icon: const Icon(
                                    Icons.audio_file_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Tambah File'),
                                ),
                                if (_controller.isAndroid)
                                  OutlinedButton.icon(
                                    onPressed:
                                        _handleRequestAndroidNotifications,
                                    icon: const Icon(
                                      Icons.notifications_active_outlined,
                                      size: 18,
                                    ),
                                    label: const Text('Izin Notifikasi'),
                                  ),
                                if (watchedFolders.isNotEmpty ||
                                    localTracks.isNotEmpty)
                                  OutlinedButton.icon(
                                    onPressed: _handleRescanFolders,
                                    icon: const Icon(
                                      Icons.refresh_rounded,
                                      size: 18,
                                    ),
                                    label: const Text('Rescan'),
                                  ),
                              ]
                            : [
                                FilledButton.tonalIcon(
                                  onPressed: _showAddUrlDialog,
                                  icon: const Icon(
                                    Icons.link_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Tambah URL Lagu'),
                                ),
                              ],
                      ),
                      if (isLocal &&
                          (watchedFolders.isNotEmpty ||
                              localTracks.isNotEmpty)) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final folder in watchedFolders)
                              Tooltip(
                                message: folder,
                                child: InputChip(
                                  backgroundColor: NovenColors.bg,
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                  avatar: const Icon(
                                    Icons.folder_rounded,
                                    size: 15,
                                    color: NovenColors.accentLight,
                                  ),
                                  label: Text(
                                    _folderDisplayName(folder),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                  deleteIconColor: NovenColors.silver,
                                  onDeleted: () =>
                                      _controller.removeLocalFolder(folder),
                                ),
                              ),
                            if (localTracks.isNotEmpty)
                              Chip(
                                backgroundColor: NovenColors.bg,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                                avatar: const Icon(
                                  Icons.storage_rounded,
                                  size: 15,
                                  color: NovenColors.silver,
                                ),
                                label: Text(
                                  () {
                                    final missingCount = localTracks
                                        .where((t) => !t.isAvailable)
                                        .length;
                                    return missingCount > 0
                                        ? '${localTracks.length} lagu di DB ($missingCount tidak tersedia)'
                                        : '${localTracks.length} lagu tersimpan di DB';
                                  }(),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: NovenColors.silver,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (!isLocal && customStreams.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final entry in customStreams)
                              Tooltip(
                                message: entry.url,
                                child: InputChip(
                                  backgroundColor: NovenColors.bg,
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                  avatar: const Icon(
                                    Icons.link_rounded,
                                    size: 15,
                                    color: NovenColors.accentLight,
                                  ),
                                  label: Text(
                                    entry.title,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                  deleteIconColor: NovenColors.silver,
                                  onDeleted: () =>
                                      _controller.removeCustomUrl(entry.url),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          _buildNowPlayingCard(),
        ],
      ),
    );
  }
}

class _AddUrlDialog extends StatefulWidget {
  const _AddUrlDialog();

  @override
  State<_AddUrlDialog> createState() => _AddUrlDialogState();
}

class _AddUrlDialogState extends State<_AddUrlDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _artistCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop((
      title: _titleCtrl.text,
      artist: _artistCtrl.text,
      url: _urlCtrl.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NovenColors.surface,
      title: const Text('Tambah URL Lagu Online'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(labelText: 'Judul Lagu'),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _artistCtrl,
            decoration: const InputDecoration(labelText: 'Artis'),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'URL Audio (.mp3 / .ogg / .flac)',
              hintText: 'https://...',
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Tambah'),
        ),
      ],
    );
  }
}
