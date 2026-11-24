import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../theme/noven_colors.dart';

class CoverArt extends StatelessWidget {
  final Track? track;
  final double size;
  final double radius;
  final bool showShadow;

  const CoverArt({
    super.key,
    required this.track,
    this.size = 48,
    this.radius = 12,
    this.showShadow = false,
  });

  Widget _buildPlaceholder() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            NovenColors.surfaceDeep,
            NovenColors.accent.withValues(alpha: 0.35),
          ],
        ),
      ),
      child: Icon(
        Icons.music_note_rounded,
        color: NovenColors.silver,
        size: size * 0.42,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (track?.coverBytes != null) {
      content = Image.memory(
        track!.coverBytes!,
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    } else if (track?.coverUrl != null) {
      content = Image.network(
        track!.coverUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildPlaceholder(),
      );
    } else {
      content = _buildPlaceholder();
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: showShadow
            ? [
                BoxShadow(
                  color: NovenColors.accent.withValues(alpha: 0.45),
                  blurRadius: 32,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: content,
      ),
    );
  }
}
