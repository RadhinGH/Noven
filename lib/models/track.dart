enum TrackSourceType { local, stream }

class Track {
  final String id;
  final String title;
  final String artist;
  final String? album;
  final String pathOrUrl;
  final TrackSourceType sourceType;
  final String? coverPath;
  final String? coverUrl;
  final Duration? duration;
  final String? lyrics;
  final DateTime? addedAt;
  final bool isAvailable;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    required this.pathOrUrl,
    required this.sourceType,
    this.coverPath,
    this.coverUrl,
    this.duration,
    this.lyrics,
    this.addedAt,
    this.isAvailable = true,
  });

  Track copyWith({
    String? title,
    String? artist,
    String? album,
    String? pathOrUrl,
    String? coverPath,
    bool clearCoverPath = false,
    String? coverUrl,
    Duration? duration,
    String? lyrics,
    DateTime? addedAt,
    bool? isAvailable,
  }) {
    return Track(
      id: id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      pathOrUrl: pathOrUrl ?? this.pathOrUrl,
      sourceType: sourceType,
      coverPath: clearCoverPath ? null : (coverPath ?? this.coverPath),
      coverUrl: coverUrl ?? this.coverUrl,
      duration: duration ?? this.duration,
      lyrics: lyrics ?? this.lyrics,
      addedAt: addedAt ?? this.addedAt,
      isAvailable: isAvailable ?? this.isAvailable,
    );
  }
}
