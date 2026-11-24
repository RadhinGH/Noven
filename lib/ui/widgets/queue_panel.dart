import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../theme/noven_colors.dart';
import 'cover_art.dart';

class QueuePanel extends StatefulWidget {
  final List<Track> playQueue;
  final List<Track> allTracks;
  final String? currentTrackId;
  final bool isSearchActive;
  final bool initialShowQueue;
  final bool showModeSwitcher;
  final ValueChanged<Track> onPlayFromQueue;
  final void Function(Track track, List<Track> list) onPlayFromAllTracks;
  final void Function(int oldIndex, int newIndex) onReorderQueue;
  final ValueChanged<int> onRemoveFromQueue;
  final VoidCallback onClearQueue;
  final ValueChanged<Track> onPlayNext;
  final ValueChanged<Track> onAddToQueue;
  final ValueChanged<Track> onAddToPlaylist;
  final ValueChanged<Track>? onToggleFavorite;
  final ValueChanged<Track>? onEditTrack;
  final ValueChanged<Track>? onRemoveTrack;

  const QueuePanel({
    super.key,
    required this.playQueue,
    required this.allTracks,
    required this.currentTrackId,
    this.isSearchActive = false,
    this.initialShowQueue = true,
    this.showModeSwitcher = true,
    required this.onPlayFromQueue,
    required this.onPlayFromAllTracks,
    required this.onReorderQueue,
    required this.onRemoveFromQueue,
    required this.onClearQueue,
    required this.onPlayNext,
    required this.onAddToQueue,
    required this.onAddToPlaylist,
    this.onToggleFavorite,
    this.onEditTrack,
    this.onRemoveTrack,
  });

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  late bool _showQueue = widget.initialShowQueue;

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final activeShowQueue = widget.showModeSwitcher
        ? (widget.isSearchActive ? false : _showQueue)
        : true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (widget.showModeSwitcher)
              Expanded(
                child: Row(
                  children: [
                    _HeaderTabPill(
                      label: 'Queue (${widget.playQueue.length})',
                      isSelected: activeShowQueue,
                      onTap: () => setState(() => _showQueue = true),
                    ),
                    const SizedBox(width: 8),
                    _HeaderTabPill(
                      label: 'All Tracks (${widget.allTracks.length})',
                      isSelected: !activeShowQueue,
                      onTap: () => setState(() => _showQueue = false),
                    ),
                  ],
                ),
              )
            else
              Expanded(
                child: Row(
                  children: [
                    const Text(
                      'Play Queue',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: NovenColors.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${widget.playQueue.length}',
                        style: TextStyle(
                          fontSize: 11,
                          color: NovenColors.silver.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (activeShowQueue && widget.playQueue.isNotEmpty)
              Tooltip(
                message: 'Kosongkan Queue',
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.delete_sweep_rounded,
                    size: 18,
                    color: NovenColors.silver.withValues(alpha: 0.72),
                  ),
                  onPressed: widget.onClearQueue,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: activeShowQueue ? _buildQueueList() : _buildAllTracksList(),
        ),
      ],
    );
  }

  Widget _buildQueueList() {
    if (widget.playQueue.isEmpty) {
      return Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: NovenColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          'Queue kosong — putar lagu atau pilih dari All Tracks.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            color: NovenColors.silver.withValues(alpha: 0.65),
          ),
        ),
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        itemCount: widget.playQueue.length,
        onReorder: widget.onReorderQueue,
        proxyDecorator: (child, index, animation) {
          return Material(
            color: Colors.transparent,
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            child: child,
          );
        },
        itemBuilder: (context, index) {
          final track = widget.playQueue[index];
          final isCurrent = track.id == widget.currentTrackId;

          return Padding(
            key: ValueKey('q_${track.id}'),
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => widget.onPlayFromQueue(track),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: isCurrent
                      ? NovenColors.accent.withValues(alpha: 0.24)
                      : NovenColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isCurrent
                        ? NovenColors.accentLight.withValues(alpha: 0.7)
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
                          color: NovenColors.silver.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    CoverArt(track: track, size: 36, radius: 9),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: isCurrent
                                  ? FontWeight.bold
                                  : FontWeight.w600,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            track.artist,
                            style: TextStyle(
                              fontSize: 11,
                              color: NovenColors.silver.withValues(alpha: 0.75),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                      tooltip: 'Hapus dari Queue',
                      icon: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: NovenColors.silver.withValues(alpha: 0.6),
                      ),
                      onPressed: () => widget.onRemoveFromQueue(index),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAllTracksList() {
    if (widget.allTracks.isEmpty) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: NovenColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          'Tidak ada lagu yang cocok.',
          style: TextStyle(
            fontSize: 12.5,
            color: NovenColors.silver.withValues(alpha: 0.65),
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: widget.allTracks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final track = widget.allTracks[index];
        final isCurrent = widget.currentTrackId == track.id;
        final isOnline = track.sourceType == TrackSourceType.stream;

        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => widget.onPlayFromAllTracks(track, widget.allTracks),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: isCurrent
                  ? NovenColors.accent.withValues(alpha: 0.22)
                  : NovenColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isCurrent
                    ? NovenColors.accentLight.withValues(alpha: 0.7)
                    : Colors.white.withValues(alpha: 0.05),
              ),
            ),
            child: Row(
              children: [
                CoverArt(track: track, size: 40, radius: 10),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isCurrent
                              ? FontWeight.bold
                              : FontWeight.w600,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        track.artist,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: NovenColors.silver.withValues(alpha: 0.75),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                if (track.isFavorite)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.favorite_rounded,
                      size: 14,
                      color: Colors.pinkAccent,
                    ),
                  ),
                if (track.duration != null)
                  Text(
                    _formatDuration(track.duration!),
                    style: TextStyle(
                      fontSize: 11,
                      color: NovenColors.silver.withValues(alpha: 0.75),
                    ),
                  )
                else
                  Icon(
                    isOnline ? Icons.cloud_rounded : Icons.laptop_rounded,
                    size: 15,
                    color: NovenColors.silver.withValues(alpha: 0.7),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Opsi Lagu',
                  icon: Icon(
                    Icons.more_vert_rounded,
                    size: 17,
                    color: NovenColors.silver.withValues(alpha: 0.7),
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
                        case 'next':
                          widget.onPlayNext(track);
                        case 'queue':
                          widget.onAddToQueue(track);
                        case 'playlist':
                          widget.onAddToPlaylist(track);
                        case 'favorite':
                          widget.onToggleFavorite?.call(track);
                        case 'edit':
                          widget.onEditTrack?.call(track);
                        case 'remove':
                          widget.onRemoveTrack?.call(track);
                      }
                    });
                  },
                  itemBuilder: (_) => [
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
                    if (widget.onToggleFavorite != null)
                      PopupMenuItem(
                        value: 'favorite',
                        child: Text(
                          track.isFavorite ? 'Hapus dari Favorit' : 'Favorit',
                        ),
                      ),
                    if (!isOnline && widget.onEditTrack != null)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Edit Info'),
                      ),
                    if (!isOnline && widget.onRemoveTrack != null)
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('Hapus dari Library'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HeaderTabPill extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _HeaderTabPill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: isSelected
              ? NovenColors.accent.withValues(alpha: 0.9)
              : NovenColors.surface,
          border: Border.all(
            color: isSelected
                ? NovenColors.accentLight.withValues(alpha: 0.8)
                : Colors.white.withValues(alpha: 0.06),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected
                ? Colors.white
                : NovenColors.silver.withValues(alpha: 0.78),
          ),
        ),
      ),
    );
  }
}
