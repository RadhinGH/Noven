import 'dart:typed_data';

enum TrackSourceType { local, stream }

class Track {
  final String id;
  final String title;
  final String artist;
  final String? album;
  final String pathOrUrl;
  final TrackSourceType sourceType;
  final Uint8List? coverBytes;
  final String? coverUrl;
  final Duration? duration;
  final String? lyrics;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    required this.pathOrUrl,
    required this.sourceType,
    this.coverBytes,
    this.coverUrl,
    this.duration,
    this.lyrics,
  });

  Track copyWith({
    String? lyrics,
    Duration? duration,
  }) {
    return Track(
      id: id,
      title: title,
      artist: artist,
      album: album,
      pathOrUrl: pathOrUrl,
      sourceType: sourceType,
      coverBytes: coverBytes,
      coverUrl: coverUrl,
      duration: duration ?? this.duration,
      lyrics: lyrics ?? this.lyrics,
    );
  }
}
