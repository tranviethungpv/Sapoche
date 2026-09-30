import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'models.dart';

/// The songs a person keeps: the ones they liked, and what they heard. The truth is kept on the native side
/// (the playback service writes the history); this holds a copy for the screens and updates it when told.
class LibraryController extends ChangeNotifier {
  LibraryController(this._backend);

  final Backend _backend;
  StreamSubscription<BackendEvent>? _subscription;

  List<Track> _liked = const [];
  Set<String> _likedIds = const {};
  List<HistoryEntry> _recent = const [];

  /// Liked songs, the most recently liked first.
  List<Track> get liked => _liked;
  List<HistoryEntry> get recent => _recent;

  bool isLiked(String videoId) => _likedIds.contains(videoId);

  final _messages = StreamController<String>.broadcast();

  /// Things that went wrong, for a snackbar.
  Stream<String> get messages => _messages.stream;

  Future<void> start() async {
    _subscription = _backend.events
        .where((e) => e is LibraryEvent)
        .listen((_) => refresh());
    await refresh();
  }

  /// Reads both lists again. Failures leave what is shown as it was.
  Future<void> refresh() async {
    try {
      final liked = await _backend.liked();
      final recent = await _backend.recent();
      _setLiked(liked);
      _recent = recent;
      notifyListeners();
    } on Object {
      // Nothing to show is better than an error on every screen
    }
  }

  /// Likes the song, or takes the like back. The heart changes at once; if the write fails it changes back.
  Future<void> toggleLike(Track track) async {
    final before = _liked;
    final wasLiked = isLiked(track.videoId);
    _setLiked(
      wasLiked
          ? [
              for (final t in _liked)
                if (t.videoId != track.videoId) t,
            ]
          : [track, ..._liked],
    );
    notifyListeners();
    try {
      await _backend.setLiked(track, !wasLiked);
    } on Object catch (e) {
      _setLiked(before);
      notifyListeners();
      _messages.add('$e');
    }
  }

  Future<void> clearHistory() async {
    final before = _recent;
    _recent = const [];
    notifyListeners();
    try {
      await _backend.clearHistory();
    } on Object catch (e) {
      _recent = before;
      notifyListeners();
      _messages.add('$e');
    }
  }

  void _setLiked(List<Track> liked) {
    _liked = liked;
    _likedIds = {for (final t in liked) t.videoId};
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _messages.close();
    super.dispose();
  }
}
