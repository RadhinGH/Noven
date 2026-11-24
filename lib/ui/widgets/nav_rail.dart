import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/noven_colors.dart';

class NovenNavRail extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onImportFolder;
  final VoidCallback onImportFiles;
  final VoidCallback onAddUrl;

  const NovenNavRail({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.onImportFolder,
    required this.onImportFiles,
    required this.onAddUrl,
  });

  static const _items = [
    (icon: Icons.home_rounded, label: 'Home'),
    (icon: Icons.library_music_rounded, label: 'Library'),
    (icon: Icons.queue_music_rounded, label: 'Playlists'),
    (icon: Icons.hub_rounded, label: 'Sources'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      decoration: BoxDecoration(
        color: NovenColors.bg,
        border: Border(
          right: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          // Logo Monogram Geometris 'N'
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: NovenColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: NovenColors.accent.withValues(alpha: 0.4),
              ),
            ),
            child: const Text(
              'N',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                height: 1,
              ),
            ),
          ),
          const SizedBox(height: 36),

          // Menu Navigasi Vertikal
          for (int i = 0; i < _items.length; i++) ...[
            _NavIconTile(
              icon: _items[i].icon,
              tooltip: _items[i].label,
              isSelected: selectedIndex == i,
              onTap: () => onSelect(i),
            ),
            const SizedBox(height: 14),
          ],

          const Spacer(),

          // Tombol '+' Lingkaran Putus-Putus di Bawah (Menu Import Cepat)
          PopupMenuButton<String>(
            tooltip: 'Tambah Musik / Sumber',
            color: NovenColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
            onSelected: (value) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                switch (value) {
                  case 'folder':
                    onImportFolder();
                  case 'files':
                    onImportFiles();
                  case 'url':
                    onAddUrl();
                }
              });
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'folder',
                child: Row(
                  children: [
                    Icon(Icons.folder_open_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('Import Folder'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'files',
                child: Row(
                  children: [
                    Icon(Icons.audio_file_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('Tambah File Lagu'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'url',
                child: Row(
                  children: [
                    Icon(Icons.link_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('Tambah URL Online'),
                  ],
                ),
              ),
            ],
            child: SizedBox(
              width: 44,
              height: 44,
              child: CustomPaint(
                painter: _DashedCirclePainter(
                  color: NovenColors.silver.withValues(alpha: 0.45),
                ),
                child: const Center(
                  child: Icon(
                    Icons.add_rounded,
                    color: NovenColors.silver,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavIconTile extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavIconTile({
    required this.icon,
    required this.tooltip,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: isSelected ? NovenColors.accent : Colors.transparent,
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: NovenColors.accent.withValues(alpha: 0.55),
                      blurRadius: 16,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            icon,
            color: isSelected
                ? Colors.white
                : NovenColors.silver.withValues(alpha: 0.55),
            size: 22,
          ),
        ),
      ),
    );
  }
}

class _DashedCirclePainter extends CustomPainter {
  final Color color;

  _DashedCirclePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    const dashCount = 12;
    const gapFraction = 0.4;
    final sweep = (2 * math.pi) / dashCount;
    final rect = Offset.zero & size;

    for (int i = 0; i < dashCount; i++) {
      canvas.drawArc(
        rect.deflate(1.5),
        i * sweep,
        sweep * (1 - gapFraction),
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) =>
      oldDelegate.color != color;
}
