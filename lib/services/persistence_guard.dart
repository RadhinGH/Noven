import 'dart:async';

import 'package:flutter/foundation.dart';

/// Guards persistence writes until initial state load finishes ([markReady])
/// and debounces frequent mutations before writing to disk.
class PersistenceGuard {
  final Duration debounceDuration;
  final Future<void> Function() _saveCallback;

  bool _isReady = false;
  bool _hasPendingSave = false;
  Timer? _debounceTimer;
  int _blockedSaveAttempts = 0;

  PersistenceGuard({
    this.debounceDuration = const Duration(milliseconds: 450),
    required Future<void> Function() onSave,
  }) : _saveCallback = onSave;

  bool get isReady => _isReady;
  bool get hasPendingSave => _hasPendingSave;
  int get blockedSaveAttempts => _blockedSaveAttempts;

  /// Enables persistence after startup load finishes. Does not replay
  /// pre-ready save attempts since those captured incomplete state.
  void markReady() {
    _isReady = true;
  }

  /// Schedules a debounced save. Ignored until [markReady] is called.
  void scheduleSave() {
    if (!_isReady) {
      _blockedSaveAttempts++;
      debugPrint(
        '[PersistenceGuard] Blocked scheduleSave before initialization completed.',
      );
      return;
    }

    _debounceTimer?.cancel();
    _hasPendingSave = true;
    _debounceTimer = Timer(debounceDuration, () {
      _hasPendingSave = false;
      _debounceTimer = null;
      _saveCallback();
    });
  }

  /// Cancels any pending debounce timer and writes immediately.
  /// Ignored until [markReady] is called.
  Future<void> saveNow() {
    if (!_isReady) {
      _blockedSaveAttempts++;
      debugPrint(
        '[PersistenceGuard] Blocked saveNow before initialization completed.',
      );
      return Future.value();
    }

    _debounceTimer?.cancel();
    _debounceTimer = null;
    _hasPendingSave = false;
    return _saveCallback();
  }

  /// Immediately writes if a debounced save is pending.
  Future<void> flushIfPending() {
    if (!_isReady || !_hasPendingSave) {
      return Future.value();
    }

    _debounceTimer?.cancel();
    _debounceTimer = null;
    _hasPendingSave = false;
    return _saveCallback();
  }

  void dispose() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _hasPendingSave = false;
  }
}
