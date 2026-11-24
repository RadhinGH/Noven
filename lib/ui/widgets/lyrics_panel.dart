import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../theme/noven_colors.dart';
import 'cover_art.dart';

class _LyricLine {
  final Duration? time;
  final String text;

  const _LyricLine({this.time, required this.text});
}

class LyricsPanel extends StatefulWidget {
  final Track? track;
  final ValueListenable<Duration> positionListenable;
  final ValueChanged<Duration> onSeek;
  final bool isFetching;
  final VoidCallback? onRefreshLyrics;

  const LyricsPanel({
    super.key,
    required this.track,
    required this.positionListenable,
    required this.onSeek,
    this.isFetching = false,
    this.onRefreshLyrics,
  });

  @override
  State<LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<LyricsPanel> {
  final ScrollController _scrollController = ScrollController();

  bool _showCoverOverride = false;
  String? _lastTrackId;
  List<_LyricLine> _parsedLines = const [];
  List<GlobalKey> _lineKeys = const [];
  bool _hasSyncedTimes = false;
  int _lastScrolledIndex = -1;

  @override
  void initState() {
    super.initState();
    _syncTrack();
  }

  @override
  void didUpdateWidget(covariant LyricsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.track?.id != _lastTrackId ||
        widget.track?.lyrics != oldWidget.track?.lyrics) {
      _syncTrack();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _syncTrack() {
    _lastTrackId = widget.track?.id;
    _showCoverOverride = false;
    _lastScrolledIndex = -1;
    final raw = widget.track?.lyrics?.trim() ?? '';
    if (raw.isEmpty) {
      _parsedLines = const [];
      _lineKeys = const [];
      _hasSyncedTimes = false;
      return;
    }

    final lrcRegex = RegExp(r'^\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\](.*)$');
    final lines = <_LyricLine>[];
    bool foundSynced = false;

    for (final rawLine in raw.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final match = lrcRegex.firstMatch(line);
      if (match != null) {
        final mins = int.parse(match.group(1)!);
        final secs = int.parse(match.group(2)!);
        final msRaw = match.group(3) ?? '0';
        final ms = int.parse(msRaw.padRight(3, '0').substring(0, 3));
        final text = match.group(4)!.trim();
        if (text.isNotEmpty) {
          foundSynced = true;
          lines.add(
            _LyricLine(
              time: Duration(minutes: mins, seconds: secs, milliseconds: ms),
              text: text,
            ),
          );
        }
      } else {
        // Lewati tag metadata LRC seperti [ar:...], [ti:...], dll
        if (RegExp(r'^\[[a-zA-Z]+:.*\]$').hasMatch(line)) continue;
        lines.add(_LyricLine(text: line));
      }
    }

    _parsedLines = lines;
    _lineKeys = List.generate(lines.length, (_) => GlobalKey());
    _hasSyncedTimes = foundSynced;
  }

  int _findActiveIndex(Duration position) {
    if (!_hasSyncedTimes) return -1;
    int active = -1;
    for (int i = 0; i < _parsedLines.length; i++) {
      final t = _parsedLines[i].time;
      if (t != null && t <= position) {
        active = i;
      }
    }
    return active;
  }

  void _scheduleAutoScroll(int activeIndex) {
    if (!_hasSyncedTimes ||
        activeIndex < 0 ||
        activeIndex == _lastScrolledIndex ||
        activeIndex >= _lineKeys.length) {
      return;
    }
    _lastScrolledIndex = activeIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (activeIndex < 0 || activeIndex >= _lineKeys.length) return;
      final ctx = _lineKeys[activeIndex].currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          alignment: 0.35,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasLyrics = _parsedLines.isNotEmpty;
    final showCoverMode = !hasLyrics || _showCoverOverride;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NovenColors.surface,
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            NovenColors.accent.withValues(alpha: 0.14),
            NovenColors.surface,
            NovenColors.surface,
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Bento Card
          Row(
            children: [
              Icon(
                showCoverMode ? Icons.album_rounded : Icons.lyrics_rounded,
                size: 18,
                color: NovenColors.accentLight,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  showCoverMode ? 'Album Cover' : 'Lyrics',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              if (hasLyrics)
                Tooltip(
                  message: _showCoverOverride
                      ? 'Lihat Lirik'
                      : 'Lihat Cover Album',
                  child: IconButton(
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    icon: Icon(
                      _showCoverOverride
                          ? Icons.lyrics_rounded
                          : Icons.image_rounded,
                      size: 20,
                      color: NovenColors.silver,
                    ),
                    onPressed: () {
                      setState(() => _showCoverOverride = !_showCoverOverride);
                    },
                  ),
                )
              else if (widget.track != null &&
                  !widget.isFetching &&
                  widget.onRefreshLyrics != null)
                Tooltip(
                  message: 'Cari lirik online',
                  child: IconButton(
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    icon: const Icon(
                      Icons.refresh_rounded,
                      size: 20,
                      color: NovenColors.silver,
                    ),
                    onPressed: widget.onRefreshLyrics,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),

          // Konten: Lirik (Synced / Plain) ATAU Cover Album Besar Fallback
          Expanded(
            child: showCoverMode
                ? _buildCoverFallback()
                : (_hasSyncedTimes
                      ? ValueListenableBuilder<Duration>(
                          valueListenable: widget.positionListenable,
                          builder: (context, position, _) =>
                              _buildLyricsList(position),
                        )
                      : _buildLyricsList(Duration.zero)),
          ),
        ],
      ),
    );
  }

  Widget _buildLyricsList(Duration position) {
    final activeIndex = _findActiveIndex(position);
    if (activeIndex >= 0) {
      _scheduleAutoScroll(activeIndex);
    }

    return SingleChildScrollView(
      controller: _scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int index = 0; index < _parsedLines.length; index++)
            _buildLyricRow(index, _parsedLines[index], index == activeIndex),
        ],
      ),
    );
  }

  Widget _buildLyricRow(int index, _LyricLine item, bool isActive) {
    if (!_hasSyncedTimes) {
      return Padding(
        key: _lineKeys[index],
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          item.text,
          style: TextStyle(
            fontSize: 14,
            height: 1.65,
            color: NovenColors.silver.withValues(alpha: 0.9),
          ),
        ),
      );
    }

    return InkWell(
      key: _lineKeys[index],
      borderRadius: BorderRadius.circular(10),
      onTap: item.time != null ? () => widget.onSeek(item.time!) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        constraints: const BoxConstraints(minHeight: 48),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: isActive
              ? NovenColors.accent.withValues(alpha: 0.25)
              : Colors.transparent,
        ),
        child: Text(
          item.text,
          style: TextStyle(
            fontSize: isActive ? 15 : 13.5,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            color: isActive
                ? Colors.white
                : NovenColors.silver.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }

  Widget _buildCoverFallback() {
    final track = widget.track;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Sisakan ruang untuk judul, artis, dan pill status di bawah cover
        final availableForCover = (constraints.maxHeight - 92).clamp(44.0, 180.0);
        final coverSize = availableForCover.clamp(
          44.0,
          constraints.maxWidth.clamp(44.0, 180.0),
        );

        return Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
              CoverArt(
                track: track,
                size: coverSize,
                radius: 20,
                showShadow: true,
              ),
              const SizedBox(height: 12),
              Text(
                track?.title ?? 'No Track Playing',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              if (track != null) ...[
                const SizedBox(height: 2),
                Text(
                  track.artist,
                  style: TextStyle(
                    fontSize: 12,
                    color: NovenColors.silver.withValues(alpha: 0.78),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: NovenColors.bg.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: widget.isFetching
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              color: NovenColors.accentLight,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Searching lyrics...',
                            style: TextStyle(
                              fontSize: 11,
                              color: NovenColors.silver.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      )
                    : Text(
                        track == null
                            ? 'Select a song to play'
                            : 'No lyrics available',
                        style: TextStyle(
                          fontSize: 11,
                          color: NovenColors.silver.withValues(alpha: 0.65),
                        ),
                      ),
              ),
            ],
            ),
          ),
        );
      },
    );
  }
}
