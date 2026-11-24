import 'package:flutter/material.dart';

import '../../models/playlist.dart';
import '../../models/track.dart';
import '../theme/noven_colors.dart';
import 'cover_art.dart';

Future<void> showAddToPlaylistDialog({
  required BuildContext context,
  required Track track,
  required List<Playlist> playlists,
  required ValueChanged<Playlist> onAddToExisting,
  required ValueChanged<String> onCreateAndAdd,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _PickPlaylistDialog(
      track: track,
      playlists: playlists,
      onAddToExisting: onAddToExisting,
      onCreateAndAdd: onCreateAndAdd,
    ),
  );
}

class PlaylistsView extends StatefulWidget {
  final List<Playlist> playlists;
  final List<Track> allTracks;
  final String? currentTrackId;
  final bool isDesktop;
  final ValueChanged<String> onCreatePlaylist;
  final void Function(String playlistId, String newName) onRenamePlaylist;
  final ValueChanged<String> onDeletePlaylist;
  final void Function(String playlistId, List<String> trackIds)
  onAddTracksToPlaylist;
  final void Function(String playlistId, int index) onRemoveTrackFromPlaylist;
  final void Function(String playlistId, int oldIndex, int newIndex)
  onReorderPlaylistTrack;
  final void Function(Track track, List<Track> queue) onPlayTrack;
  final ValueChanged<List<Track>> onShufflePlaylist;
  final ValueChanged<Track>? onLocateTrack;
  final ValueChanged<Track>? onRemoveTrackFromLibrary;
  final String? selectedPlaylistId;
  final ValueChanged<String?>? onSelectedPlaylistChanged;

  const PlaylistsView({
    super.key,
    required this.playlists,
    required this.allTracks,
    required this.currentTrackId,
    required this.isDesktop,
    required this.onCreatePlaylist,
    required this.onRenamePlaylist,
    required this.onDeletePlaylist,
    required this.onAddTracksToPlaylist,
    required this.onRemoveTrackFromPlaylist,
    required this.onReorderPlaylistTrack,
    required this.onPlayTrack,
    required this.onShufflePlaylist,
    this.onLocateTrack,
    this.onRemoveTrackFromLibrary,
    this.selectedPlaylistId,
    this.onSelectedPlaylistChanged,
  });

  @override
  State<PlaylistsView> createState() => _PlaylistsViewState();
}

class _PlaylistsViewState extends State<PlaylistsView> {
  String? _selectedPlaylistId;

  String? get _effectiveSelectedId =>
      widget.selectedPlaylistId ?? _selectedPlaylistId;

  void _setSelectedPlaylistId(String? id) {
    setState(() => _selectedPlaylistId = id);
    widget.onSelectedPlaylistChanged?.call(id);
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Playlist? _resolveSelectedPlaylist() {
    if (widget.playlists.isEmpty) return null;
    final activeId = _effectiveSelectedId;
    if (activeId != null) {
      for (final p in widget.playlists) {
        if (p.id == activeId) return p;
      }
    }
    return widget.isDesktop ? widget.playlists.first : null;
  }

  Future<void> _promptCreatePlaylist() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _PlaylistNameDialog(
        title: 'Buat Playlist Baru',
        confirmLabel: 'Buat',
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      widget.onCreatePlaylist(name.trim());
    }
  }

  Future<void> _promptRenamePlaylist(Playlist playlist) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _PlaylistNameDialog(
        title: 'Ubah Nama Playlist',
        confirmLabel: 'Simpan',
        initialValue: playlist.name,
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      widget.onRenamePlaylist(playlist.id, name.trim());
    }
  }

  Future<void> _promptAddTracks(Playlist playlist) async {
    final selectedIds = await showDialog<List<String>>(
      context: context,
      builder: (_) => _AddTracksToPlaylistDialog(
        playlist: playlist,
        allTracks: widget.allTracks,
      ),
    );
    if (selectedIds != null && selectedIds.isNotEmpty) {
      widget.onAddTracksToPlaylist(playlist.id, selectedIds);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trackMap = {for (final t in widget.allTracks) t.id: t};
    final selected = _resolveSelectedPlaylist();

    return LayoutBuilder(
      builder: (context, constraints) {
        final showSplit = constraints.maxWidth >= 760;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Playlists',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '${widget.playlists.length} playlist tersimpan (Lokal + Online)',
                      style: TextStyle(
                        fontSize: 13,
                        color: NovenColors.silver.withValues(alpha: 0.72),
                      ),
                    ),
                  ],
                ),
                FilledButton.icon(
                  onPressed: _promptCreatePlaylist,
                  style: FilledButton.styleFrom(
                    backgroundColor: NovenColors.accent,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.playlist_add_rounded, size: 19),
                  label: const Text('Buat Playlist'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: widget.playlists.isEmpty
                  ? _buildEmptyState()
                  : showSplit
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 280,
                          child: _buildPlaylistList(trackMap, selected?.id),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: selected != null
                              ? _buildPlaylistDetail(
                                  selected,
                                  trackMap,
                                  showBackButton: false,
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    )
                  : (selected != null && _effectiveSelectedId != null)
                  ? _buildPlaylistDetail(
                      selected,
                      trackMap,
                      showBackButton: true,
                    )
                  : _buildPlaylistList(trackMap, _effectiveSelectedId),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Container(
      width: double.infinity,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: NovenColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          Icon(
            Icons.queue_music_rounded,
            size: 48,
            color: NovenColors.accentLight.withValues(alpha: 0.8),
          ),
          const SizedBox(height: 12),
          const Text(
            'Belum ada Playlist',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Gabungkan lagu lokal (.flac/.mp3) dan stream online favorit kamu dalam 1 playlist.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: NovenColors.silver.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _promptCreatePlaylist,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Buat Playlist Pertama'),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildPlaylistList(
    Map<String, Track> trackMap,
    String? activePlaylistId,
  ) {
    return ListView.separated(
      itemCount: widget.playlists.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final pl = widget.playlists[index];
        final isSelected = pl.id == activePlaylistId;
        final resolved = pl.trackIds
            .map((id) => trackMap[id])
            .whereType<Track>()
            .toList();
        final coverTrack = resolved.isEmpty ? null : resolved.first;

        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _setSelectedPlaylistId(pl.id),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isSelected
                  ? NovenColors.accent.withValues(alpha: 0.24)
                  : NovenColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected
                    ? NovenColors.accentLight.withValues(alpha: 0.75)
                    : Colors.white.withValues(alpha: 0.06),
              ),
            ),
            child: Row(
              children: [
                CoverArt(track: coverTrack, size: 46, radius: 11),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pl.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${resolved.length} lagu',
                        style: TextStyle(
                          fontSize: 12,
                          color: NovenColors.silver.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Kelola Playlist',
                  icon: Icon(
                    Icons.more_vert_rounded,
                    size: 18,
                    color: NovenColors.silver.withValues(alpha: 0.78),
                  ),
                  color: NovenColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  onSelected: (value) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      switch (value) {
                        case 'rename':
                          _promptRenamePlaylist(pl);
                        case 'delete':
                          if (_effectiveSelectedId == pl.id) {
                            _setSelectedPlaylistId(null);
                          }
                          widget.onDeletePlaylist(pl.id);
                      }
                    });
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaylistDetail(
    Playlist playlist,
    Map<String, Track> trackMap, {
    required bool showBackButton,
  }) {
    final entries = <({int rawIndex, Track track})>[];
    for (int i = 0; i < playlist.trackIds.length; i++) {
      final t = trackMap[playlist.trackIds[i]];
      if (t != null) {
        entries.add((rawIndex: i, track: t));
      }
    }
    final resolvedTracks = entries.map((e) => e.track).toList();
    final playableTracks = resolvedTracks.where((t) => t.isAvailable).toList();
    final unavailableCount = resolvedTracks.length - playableTracks.length;
    final coverTrack = resolvedTracks.isEmpty ? null : resolvedTracks.first;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NovenColors.surfaceDeep,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showBackButton) ...[
            TextButton.icon(
              onPressed: () => _setSelectedPlaylistId(null),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('Semua Playlist'),
            ),
            const SizedBox(height: 6),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 380;
              return Row(
                children: [
                  CoverArt(
                    track: coverTrack,
                    size: isCompact ? 58 : 76,
                    radius: 16,
                    showShadow: true,
                  ),
                  SizedBox(width: isCompact ? 12 : 16),
                  Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      unavailableCount > 0
                          ? '${playableTracks.length} tersedia • $unavailableCount tidak tersedia'
                          : '${resolvedTracks.length} lagu tersedia',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: NovenColors.silver.withValues(alpha: 0.78),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: playableTracks.isEmpty
                              ? null
                              : () => widget.onPlayTrack(
                                  playableTracks.first,
                                  playableTracks,
                                ),
                          style: FilledButton.styleFrom(
                            backgroundColor: NovenColors.accent,
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: const Text('Play'),
                        ),
                        OutlinedButton.icon(
                          onPressed: playableTracks.isEmpty
                              ? null
                              : () => widget.onShufflePlaylist(playableTracks),
                          icon: const Icon(Icons.shuffle_rounded, size: 17),
                          label: const Text('Shuffle'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _promptAddTracks(playlist),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Tambah Lagu'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
            },
          ),
          const SizedBox(height: 16),
          Expanded(
            child: resolvedTracks.isEmpty
                ? Center(
                    child: Text(
                      'Playlist masih kosong.\nKlik "Tambah Lagu" untuk memilih lagu lokal maupun online.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: NovenColors.silver.withValues(alpha: 0.68),
                      ),
                    ),
                  )
                : Material(
                    type: MaterialType.transparency,
                    child: ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: entries.length,
                      onReorder: (oldIdx, newIdx) {
                        widget.onReorderPlaylistTrack(
                          playlist.id,
                          oldIdx,
                          newIdx,
                        );
                      },
                      proxyDecorator: (child, index, animation) {
                        return Material(
                          color: Colors.transparent,
                          elevation: 8,
                          borderRadius: BorderRadius.circular(14),
                          child: child,
                        );
                      },
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final track = entry.track;
                        final isCurrent = track.id == widget.currentTrackId;
                        final isOnline =
                            track.sourceType == TrackSourceType.stream;

                        return Padding(
                          key: ValueKey('pl_${playlist.id}_${track.id}_$index'),
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Opacity(
                            opacity: track.isAvailable ? 1.0 : 0.62,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () => widget.onPlayTrack(
                                track,
                                playableTracks.isNotEmpty
                                    ? playableTracks
                                    : resolvedTracks,
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: isCurrent
                                      ? NovenColors.accent.withValues(
                                          alpha: 0.24,
                                        )
                                      : NovenColors.surface,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: !track.isAvailable
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
                                    ReorderableDragStartListener(
                                      index: index,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 6,
                                        ),
                                        child: Icon(
                                          Icons.drag_handle_rounded,
                                          size: 18,
                                          color: NovenColors.silver.withValues(
                                            alpha: 0.55,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    CoverArt(track: track, size: 40, radius: 10),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            track.title,
                                            style: TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: isCurrent
                                                  ? FontWeight.bold
                                                  : FontWeight.w600,
                                              color: Colors.white,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(
                                            track.isAvailable
                                                ? track.artist
                                                : '${track.artist} • Tidak tersedia',
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              color: track.isAvailable
                                                  ? NovenColors.silver
                                                        .withValues(alpha: 0.75)
                                                  : Colors.amberAccent
                                                        .withValues(alpha: 0.9),
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (!track.isAvailable &&
                                        widget.onLocateTrack != null)
                                      IconButton(
                                        constraints: const BoxConstraints(
                                          minWidth: 48,
                                          minHeight: 48,
                                        ),
                                        tooltip: 'Locate ulang file',
                                        icon: const Icon(
                                          Icons.folder_open_rounded,
                                          size: 19,
                                          color: Colors.amberAccent,
                                        ),
                                        onPressed: () =>
                                            widget.onLocateTrack!(track),
                                      )
                                    else
                                      Icon(
                                        isOnline
                                            ? Icons.cloud_rounded
                                            : Icons.laptop_rounded,
                                        size: 14,
                                        color: NovenColors.silver.withValues(
                                          alpha: 0.65,
                                        ),
                                      ),
                                    if (track.duration != null) ...[
                                      const SizedBox(width: 8),
                                      Text(
                                        _formatDuration(track.duration!),
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: NovenColors.silver.withValues(
                                            alpha: 0.75,
                                          ),
                                        ),
                                      ),
                                    ],
                                    IconButton(
                                      constraints: const BoxConstraints(
                                        minWidth: 48,
                                        minHeight: 48,
                                      ),
                                      tooltip: 'Hapus dari Playlist',
                                      icon: Icon(
                                        Icons.close_rounded,
                                        size: 19,
                                        color: NovenColors.silver.withValues(
                                          alpha: 0.65,
                                        ),
                                      ),
                                      onPressed: () =>
                                          widget.onRemoveTrackFromPlaylist(
                                            playlist.id,
                                            entry.rawIndex,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistNameDialog extends StatefulWidget {
  final String title;
  final String confirmLabel;
  final String initialValue;

  const _PlaylistNameDialog({
    required this.title,
    required this.confirmLabel,
    this.initialValue = '',
  });

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NovenColors.surface,
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Nama Playlist'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

class _AddTracksToPlaylistDialog extends StatefulWidget {
  final Playlist playlist;
  final List<Track> allTracks;

  const _AddTracksToPlaylistDialog({
    required this.playlist,
    required this.allTracks,
  });

  @override
  State<_AddTracksToPlaylistDialog> createState() =>
      _AddTracksToPlaylistDialogState();
}

class _AddTracksToPlaylistDialogState
    extends State<_AddTracksToPlaylistDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  final Set<String> _selectedIds = {};
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.playlist.trackIds.toSet();
    final q = _query.trim().toLowerCase();
    final filtered = widget.allTracks.where((t) {
      if (q.isEmpty) return true;
      return t.title.toLowerCase().contains(q) ||
          t.artist.toLowerCase().contains(q) ||
          (t.album?.toLowerCase().contains(q) ?? false);
    }).toList();

    return AlertDialog(
      backgroundColor: NovenColors.surface,
      title: Text('Tambah Lagu ke "${widget.playlist.name}"'),
      content: SizedBox(
        width: 440,
        height: 380,
        child: Column(
          children: [
            TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Cari lagu atau artis...',
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'Tidak ada lagu tersedia.',
                        style: TextStyle(
                          color: NovenColors.silver.withValues(alpha: 0.65),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final track = filtered[index];
                        final alreadyIn = existing.contains(track.id);
                        final checked =
                            alreadyIn || _selectedIds.contains(track.id);

                        return CheckboxListTile(
                          value: checked,
                          enabled: !alreadyIn,
                          activeColor: NovenColors.accent,
                          contentPadding: EdgeInsets.zero,
                          secondary: CoverArt(
                            track: track,
                            size: 36,
                            radius: 8,
                          ),
                          title: Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              color: Colors.white,
                            ),
                          ),
                          subtitle: Text(
                            alreadyIn ? '${track.artist} • Sudah ada' : track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: NovenColors.silver.withValues(alpha: 0.72),
                            ),
                          ),
                          onChanged: alreadyIn
                              ? null
                              : (val) {
                                  setState(() {
                                    if (val == true) {
                                      _selectedIds.add(track.id);
                                    } else {
                                      _selectedIds.remove(track.id);
                                    }
                                  });
                                },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _selectedIds.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selectedIds.toList()),
          child: Text('Tambah (${_selectedIds.length})'),
        ),
      ],
    );
  }
}

class _PickPlaylistDialog extends StatefulWidget {
  final Track track;
  final List<Playlist> playlists;
  final ValueChanged<Playlist> onAddToExisting;
  final ValueChanged<String> onCreateAndAdd;

  const _PickPlaylistDialog({
    required this.track,
    required this.playlists,
    required this.onAddToExisting,
    required this.onCreateAndAdd,
  });

  @override
  State<_PickPlaylistDialog> createState() => _PickPlaylistDialogState();
}

class _PickPlaylistDialogState extends State<_PickPlaylistDialog> {
  final TextEditingController _newNameCtrl = TextEditingController();

  @override
  void dispose() {
    _newNameCtrl.dispose();
    super.dispose();
  }

  void _createAndSubmit() {
    final name = _newNameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop();
    widget.onCreateAndAdd(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NovenColors.surface,
      title: Text(
        'Simpan "${widget.track.title}" ke Playlist',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.playlists.isNotEmpty) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.playlists.length,
                  itemBuilder: (context, index) {
                    final pl = widget.playlists[index];
                    final alreadyIn = pl.trackIds.contains(widget.track.id);

                    return ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.queue_music_rounded,
                        color: NovenColors.accentLight,
                      ),
                      title: Text(
                        pl.name,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        alreadyIn
                            ? 'Sudah ada di playlist'
                            : '${pl.trackIds.length} lagu',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: NovenColors.silver.withValues(alpha: 0.72),
                        ),
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.onAddToExisting(pl);
                      },
                    );
                  },
                ),
              ),
              const Divider(),
            ],
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Atau buat playlist baru...',
                    ),
                    onSubmitted: (_) => _createAndSubmit(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _createAndSubmit,
                  child: const Text('Buat'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Tutup'),
        ),
      ],
    );
  }
}
