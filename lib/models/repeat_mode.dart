enum PlaybackRepeatMode {
  off,
  all,
  one;

  PlaybackRepeatMode get next {
    switch (this) {
      case PlaybackRepeatMode.off:
        return PlaybackRepeatMode.all;
      case PlaybackRepeatMode.all:
        return PlaybackRepeatMode.one;
      case PlaybackRepeatMode.one:
        return PlaybackRepeatMode.off;
    }
  }

  String get tooltip {
    switch (this) {
      case PlaybackRepeatMode.off:
        return 'Repeat: Off';
      case PlaybackRepeatMode.all:
        return 'Repeat: All';
      case PlaybackRepeatMode.one:
        return 'Repeat: One';
    }
  }

  static PlaybackRepeatMode fromName(String? value) {
    for (final mode in PlaybackRepeatMode.values) {
      if (mode.name == value) return mode;
    }
    return PlaybackRepeatMode.all;
  }
}
