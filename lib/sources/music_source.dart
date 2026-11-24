import '../models/track.dart';

/// Kontrak standar untuk SEMUA sumber musik di Noven (Pola Aggregator).
/// Sumber apa pun (Lokal, Online, Cloud, Server Pribadi) wajib mengikuti cetakan ini.
abstract class MusicSource {
  String get id;
  String get name;
  String get description;
  bool isEnabled = true;

  Future<List<Track>> fetchTracks();
}
