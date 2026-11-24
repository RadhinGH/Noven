import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/repeat_mode.dart';
import '../../models/track.dart';
import '../theme/noven_colors.dart';
import 'cover_art.dart';

class NowPlayingCard extends StatelessWidget {
  final Track? track;
  final bool isPlaying;
  final bool isLoading;
  final ValueListenable<Duration> positionListenable;
  final Duration duration;
  final bool isSeeking;
  final double seekValueMs;
  final double volume;
  final bool isMuted;
  final bool isShuffle;
  final PlaybackRepeatMode repeatMode;
  final VoidCallback onTogglePlay;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToggleShuffle;
  final VoidCallback onCycleRepeat;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<double> onSeekChange;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<double> onVolumeChange;
  final ValueChanged<double>? onVolumeChangeEnd;
  final VoidCallback onToggleMute;
  final VoidCallback? onOpenQueue;
  final int queueCount;

  const NowPlayingCard({
    super.key,
    required this.track,
    required this.isPlaying,
    required this.isLoading,
    required this.positionListenable,
    required this.duration,
    required this.isSeeking,
    required this.seekValueMs,
    required this.volume,
    required this.isMuted,
    required this.isShuffle,
    required this.repeatMode,
    required this.onTogglePlay,
    required this.onPrev,
    required this.onNext,
    required this.onToggleShuffle,
    required this.onCycleRepeat,
    required this.onSeekStart,
    required this.onSeekChange,
    required this.onSeekEnd,
    required this.onVolumeChange,
    this.onVolumeChangeEnd,
    required this.onToggleMute,
    this.onOpenQueue,
    this.queueCount = 0,
  });

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final effectiveVolume = isMuted ? 0.0 : volume;
    final isRepeatActive = repeatMode != PlaybackRepeatMode.off;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: NovenColors.surface,
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            NovenColors.surface,
            NovenColors.accent.withValues(alpha: 0.2),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showVolumeSlider = constraints.maxWidth >= 430;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Baris Atas: Cover + Judul/Artis + Timestamp + Volume
              Row(
                children: [
                  CoverArt(track: track, size: 46, radius: 12),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track?.title ?? 'Now Playing',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.white,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track?.artist ?? 'Noven Player',
                          style: TextStyle(
                            fontSize: 12,
                            color: NovenColors.silver.withValues(alpha: 0.78),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ValueListenableBuilder<Duration>(
                    valueListenable: positionListenable,
                    builder: (context, position, _) {
                      final displayPosition = isSeeking
                          ? Duration(milliseconds: seekValueMs.toInt())
                          : position;
                      return Text(
                        '${_formatDuration(displayPosition)} / ${_formatDuration(duration)}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: NovenColors.silver.withValues(alpha: 0.8),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 6),
                  if (onOpenQueue != null)
                    Tooltip(
                      message: 'Play Queue ($queueCount)',
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(
                          Icons.playlist_play_rounded,
                          size: 20,
                          color: NovenColors.silver,
                        ),
                        onPressed: onOpenQueue,
                      ),
                    ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      effectiveVolume == 0
                          ? Icons.volume_off_rounded
                          : effectiveVolume < 0.5
                              ? Icons.volume_down_rounded
                              : Icons.volume_up_rounded,
                      size: 19,
                      color: NovenColors.silver,
                    ),
                    onPressed: onToggleMute,
                  ),
                  if (showVolumeSlider)
                    SizedBox(
                      width: 96,
                      child: Slider(
                        value: effectiveVolume,
                        min: 0.0,
                        max: 1.0,
                        activeColor: NovenColors.accentLight,
                        inactiveColor: Colors.white12,
                        onChanged: onVolumeChange,
                        onChangeEnd: onVolumeChangeEnd,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),

              // Baris Bawah: Shuffle / Prev / Play-Pause / Next / Repeat + Seek Slider
              Row(
                children: [
                  _ModeIconButton(
                    icon: Icons.shuffle_rounded,
                    tooltip: isShuffle ? 'Shuffle: On' : 'Shuffle: Off',
                    isActive: isShuffle,
                    onPressed: onToggleShuffle,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(
                      Icons.skip_previous_rounded,
                      color: NovenColors.silver,
                    ),
                    onPressed: onPrev,
                  ),
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: NovenColors.accent.withValues(alpha: 0.55),
                          blurRadius: 14,
                        ),
                      ],
                    ),
                    child: IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: NovenColors.accent,
                        disabledBackgroundColor: NovenColors.accent.withValues(
                          alpha: 0.72,
                        ),
                        fixedSize: const Size(38, 38),
                        padding: EdgeInsets.zero,
                      ),
                      icon: isLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                      onPressed: isLoading ? null : onTogglePlay,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(
                      Icons.skip_next_rounded,
                      color: NovenColors.silver,
                    ),
                    onPressed: onNext,
                  ),
                  _ModeIconButton(
                    icon: repeatMode == PlaybackRepeatMode.one
                        ? Icons.repeat_one_rounded
                        : Icons.repeat_rounded,
                    tooltip: repeatMode.tooltip,
                    isActive: isRepeatActive,
                    onPressed: onCycleRepeat,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SizedBox(
                      height: 24,
                      child: ValueListenableBuilder<Duration>(
                        valueListenable: positionListenable,
                        builder: (context, position, _) {
                          final currentMs = (isSeeking
                                  ? seekValueMs
                                  : position.inMilliseconds.toDouble())
                              .clamp(0.0, maxMs);
                          return Slider(
                            value: currentMs,
                            max: maxMs,
                            activeColor: NovenColors.accentLight,
                            inactiveColor: Colors.white12,
                            onChangeStart: onSeekStart,
                            onChanged: onSeekChange,
                            onChangeEnd: onSeekEnd,
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ModeIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final VoidCallback onPressed;

  const _ModeIconButton({
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: isActive
                  ? NovenColors.accentLight
                  : NovenColors.silver.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 2),
            Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive ? NovenColors.accentLight : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
