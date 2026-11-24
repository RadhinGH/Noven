import '../models/track.dart';
import '../services/storage_service.dart';
import 'music_source.dart';

class OnlineStreamSource extends MusicSource {
  static const List<Track> _demoTracks = [
    Track(
      id: 'online_soundhelix_1',
      title: 'SoundHelix Song 1 (Demo Stream)',
      artist: 'T. Schürger',
      album: 'Online Demo',
      pathOrUrl:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
      sourceType: TrackSourceType.stream,
      coverUrl: 'https://picsum.photos/seed/noven1/300/300',
    ),
    Track(
      id: 'online_soundhelix_2',
      title: 'SoundHelix Song 2 (Demo Stream)',
      artist: 'T. Schürger',
      album: 'Online Demo',
      pathOrUrl:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3',
      sourceType: TrackSourceType.stream,
      coverUrl: 'https://picsum.photos/seed/noven2/300/300',
    ),
  ];

  final List<CustomStreamEntry> _customEntries = [];

  @override
  String get id => 'online';

  @override
  String get name => 'Online Streams';

  @override
  String get description =>
      'Streaming audio langsung dari URL internet (gratis + URL kustom)';

  List<CustomStreamEntry> get customStreams => List.unmodifiable(_customEntries);

  @override
  Future<List<Track>> fetchTracks() async => List.unmodifiable([
        ..._demoTracks,
        ..._customEntries.map(_toTrack),
      ]);

  /// Menambahkan URL lagu online kustom milik user
  bool addCustomUrl({
    required String title,
    required String artist,
    required String url,
  }) {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) return false;
    if (_customEntries.any((e) => e.url == trimmedUrl)) return false;

    _customEntries.add(
      CustomStreamEntry(
        title: title.trim().isEmpty ? 'Untitled Stream' : title.trim(),
        artist: artist.trim().isEmpty ? 'Web Stream' : artist.trim(),
        url: trimmedUrl,
      ),
    );
    return true;
  }

  void removeCustomUrl(String url) {
    _customEntries.removeWhere((e) => e.url == url);
  }

  void restoreCustomStreams(List<CustomStreamEntry> entries) {
    _customEntries.clear();
    for (final entry in entries) {
      final url = entry.url.trim();
      if (url.isEmpty) continue;
      if (_customEntries.any((e) => e.url == url)) continue;
      _customEntries.add(
        CustomStreamEntry(
          title: entry.title.trim().isEmpty
              ? 'Untitled Stream'
              : entry.title.trim(),
          artist: entry.artist.trim().isEmpty
              ? 'Web Stream'
              : entry.artist.trim(),
          url: url,
        ),
      );
    }
  }

  Track _toTrack(CustomStreamEntry entry) {
    return Track(
      id: entry.url,
      title: entry.title,
      artist: entry.artist,
      album: 'Custom URL',
      pathOrUrl: entry.url,
      sourceType: TrackSourceType.stream,
    );
  }
}
