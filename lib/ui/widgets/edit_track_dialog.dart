import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../theme/noven_colors.dart';

Future<({String title, String artist, String? album})?> showEditTrackDialog(
  BuildContext context,
  Track track,
) {
  return showDialog<({String title, String artist, String? album})>(
    context: context,
    builder: (_) => _EditTrackDialog(track: track),
  );
}

class _EditTrackDialog extends StatefulWidget {
  final Track track;

  const _EditTrackDialog({required this.track});

  @override
  State<_EditTrackDialog> createState() => _EditTrackDialogState();
}

class _EditTrackDialogState extends State<_EditTrackDialog> {
  late final TextEditingController _titleCtrl = TextEditingController(
    text: widget.track.title,
  );
  late final TextEditingController _artistCtrl = TextEditingController(
    text: widget.track.artist,
  );
  late final TextEditingController _albumCtrl = TextEditingController(
    text: widget.track.album ?? '',
  );

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _albumCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final cleanTitle = _titleCtrl.text.trim();
    if (cleanTitle.isEmpty) return;

    final rawArtist = _artistCtrl.text.trim();
    final rawAlbum = _albumCtrl.text.trim();

    Navigator.of(context).pop((
      title: cleanTitle,
      artist: rawArtist.isEmpty ? 'Unknown Artist' : rawArtist,
      album: rawAlbum.isEmpty ? null : rawAlbum,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NovenColors.surface,
      title: const Text('Edit Info Lagu'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _titleCtrl,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Judul Lagu'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _artistCtrl,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Artis'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _albumCtrl,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'Album (opsional)'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Text(
              'Perubahan hanya disimpan di database Noven — file audio asli tidak diubah.',
              style: TextStyle(
                fontSize: 11.5,
                color: NovenColors.silver.withValues(alpha: 0.7),
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
          onPressed: _submit,
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
