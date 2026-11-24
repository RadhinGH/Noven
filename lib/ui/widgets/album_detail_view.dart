import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../theme/noven_colors.dart';
import 'cover_art.dart';

class AlbumDetailView extends StatelessWidget {
  final String albumName;
  final String artist;
  final List<Track> tracks;
  final String? currentTrackId;
  final bool isPlaying;
  final VoidCallback onBack;
  final void Function(Track track, List<Track> queue) onPlayTrack;
  final void Function(List<Track> tracks) onShuffleAlbum;
  final void Function(List<Track> tracks) onAddAlbumToQueue;
  final ValueChanged<Track> onPlayNext;
  final ValueChanged<Track> onAddToQueue;
  final ValueChanged<Track> onAddToPlaylist;
  final ValueChanged<Track>? onToggleFavorite;
  final ValueChanged<Track>? onEditTrack;
  final ValueChanged<Track>? onRemoveTrack;

  const AlbumDetailView({
    super.key,
    required this.albumName,
    required this.artist,
    required this.tracks,
    required this.currentTrackId,
    required this.isPlaying,
    required this.onBack,
    required this.onPlayTrack,
    required this.onShuffleAlbum,
    required this.onAddAlbumToQueue,
    required this.onPlayNext,
    required this.onAddToQueue,
    required this.onAddToPlaylist,
    this.onToggleFavorite,
    this.onEditTrack,
    this.onRemoveTrack,
  });

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) return '$hours:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final firstTrack = tracks.isEmpty ? null : tracks.first;
    final totalDuration = tracks.fold<Duration>(
      Duration.zero,
      (acc, t) => acc + (t.duration ?? Duration.zero),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top Back Bar
        Row(
          children: [
            IconButton(
              tooltip: 'Kembali ke Home',
              onPressed: onBack,
              style: IconButton.styleFrom(
                backgroundColor: NovenColors.surface,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                albumName,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Album Hero Header Card
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                NovenColors.accent,
                Color(0xFF473C78),
                NovenColors.surface,
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CoverArt(
                track: firstTrack,
                size: 112,
                radius: 18,
                showShadow: true,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Text(
                        'ALBUM',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      albumName,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      totalDuration > Duration.zero
                          ? '$artist • ${tracks.length} track • ${_formatDuration(totalDuration)}'
                          : '$artist • ${tracks.length} track',
                      style: TextStyle(
                        fontSize: 13,
                        color: NovenColors.silver.withValues(alpha: 0.88),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: tracks.isEmpty
                              ? null
                              : () => onPlayTrack(tracks.first, tracks),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: NovenColors.bg,
                          ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 19),
                          label: const Text(
                            'Play',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: tracks.isEmpty
                              ? null
                              : () => onShuffleAlbum(tracks),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.35),
                            ),
                          ),
                          icon: const Icon(Icons.shuffle_rounded, size: 18),
                          label: const Text('Shuffle'),
                        ),
                        OutlinedButton.icon(
                          onPressed: tracks.isEmpty
                              ? null
                              : () => onAddAlbumToQueue(tracks),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: NovenColors.silver,
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.22),
                            ),
                          ),
                          icon: const Icon(Icons.playlist_add_rounded, size: 18),
                          label: const Text('Add to Queue'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Tracklist
        Expanded(
          child: tracks.isEmpty
              ? Center(
                  child: Text(
                    'Album ini tidak memiliki lagu.',
                    style: TextStyle(
                      color: NovenColors.silver.withValues(alpha: 0.65),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: tracks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final track = tracks[index];
                    final isCurrent = track.id == currentTrackId;
                    final numLabel = (index + 1).toString().padLeft(2, '0');

                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => onPlayTrack(track, tracks),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
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
                            SizedBox(
                              width: 28,
                              child: Center(
                                child: isCurrent && isPlaying
                                    ? const Icon(
                                        Icons.graphic_eq_rounded,
                                        size: 18,
                                        color: NovenColors.accentLight,
                                      )
                                    : Text(
                                        numLabel,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                          color: isCurrent
                                              ? NovenColors.accentLight
                                              : NovenColors.silver.withValues(
                                                  alpha: 0.6,
                                                ),
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            CoverArt(track: track, size: 40, radius: 10),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                                    track.artist,
                                    style: TextStyle(
                                      fontSize: 11.5,
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
                            if (track.isFavorite)
                              const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: Icon(
                                  Icons.favorite_rounded,
                                  size: 15,
                                  color: Colors.pinkAccent,
                                ),
                              ),
                            if (track.lyrics != null &&
                                track.lyrics!.trim().isNotEmpty)
                              const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: Icon(
                                  Icons.lyrics_rounded,
                                  size: 15,
                                  color: NovenColors.accentLight,
                                ),
                              ),
                            if (track.duration != null)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Text(
                                  _formatDuration(track.duration!),
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: NovenColors.silver.withValues(
                                      alpha: 0.75,
                                    ),
                                  ),
                                ),
                              ),
                            PopupMenuButton<String>(
                              tooltip: 'Opsi Lagu',
                              icon: Icon(
                                Icons.more_vert_rounded,
                                size: 18,
                                color: NovenColors.silver.withValues(alpha: 0.75),
                              ),
                              color: NovenColors.surface,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              onSelected: (value) {
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  switch (value) {
                                    case 'next':
                                      onPlayNext(track);
                                    case 'queue':
                                      onAddToQueue(track);
                                    case 'playlist':
                                      onAddToPlaylist(track);
                                    case 'favorite':
                                      onToggleFavorite?.call(track);
                                    case 'edit':
                                      onEditTrack?.call(track);
                                    case 'remove':
                                      onRemoveTrack?.call(track);
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
                                if (onToggleFavorite != null)
                                  PopupMenuItem(
                                    value: 'favorite',
                                    child: Text(
                                      track.isFavorite
                                          ? 'Hapus dari Favorit'
                                          : 'Favorit',
                                    ),
                                  ),
                                if (track.sourceType ==
                                        TrackSourceType.local &&
                                    onEditTrack != null)
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Edit Info'),
                                  ),
                                if (track.sourceType ==
                                        TrackSourceType.local &&
                                    onRemoveTrack != null)
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
                ),
        ),
      ],
    );
  }
}
