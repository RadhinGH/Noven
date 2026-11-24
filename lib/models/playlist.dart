class Playlist {
  final String id;
  final String name;
  final List<String> trackIds;
  final DateTime createdAt;

  const Playlist({
    required this.id,
    required this.name,
    required this.trackIds,
    required this.createdAt,
  });

  Playlist copyWith({
    String? name,
    List<String>? trackIds,
  }) {
    return Playlist(
      id: id,
      name: name ?? this.name,
      trackIds: trackIds ?? this.trackIds,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'trackIds': trackIds,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Playlist.fromJson(Map<String, dynamic> json) {
    final rawId = (json['id'] as String? ?? '').trim();
    final rawName = (json['name'] as String? ?? 'Untitled Playlist').trim();
    final rawTrackIds = json['trackIds'];
    final trackIds = rawTrackIds is List
        ? rawTrackIds
            .whereType<String>()
            .where((s) => s.trim().isNotEmpty)
            .toList()
        : <String>[];
    final parsedDate = DateTime.tryParse(json['createdAt'] as String? ?? '');

    return Playlist(
      id: rawId.isEmpty
          ? 'pl_${DateTime.now().microsecondsSinceEpoch}'
          : rawId,
      name: rawName.isEmpty ? 'Untitled Playlist' : rawName,
      trackIds: trackIds,
      createdAt: parsedDate ?? DateTime.now(),
    );
  }
}
