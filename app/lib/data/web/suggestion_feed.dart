import 'dart:async';

import 'library_store.dart';
import 'taste.dart';
import 'wire.dart';

/// What to offer to play. YouTube lists related songs beside any song, so suggestions come from a few songs the person
/// loves most (the seeds, chosen by [Taste] from what they heard, liked and left after a few seconds). The lists are kept
/// for [freshMs], so opening the app shows them at once, even offline, and the network is only used to renew them.
/// Dart counterpart of `SuggestionFeed.kt`.
class SuggestionFeed {
  SuggestionFeed({
    required this.store,
    required this.radio,
    int Function()? now,
    void Function(String line)? log,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _log = log ?? ((_) {});

  final LibraryStore store;

  /// The radio YouTube Music makes of a song: the songs to carry on with after it.
  final Future<List<TrackRef>> Function(String videoId) radio;
  final int Function() _now;
  final void Function(String line) _log;

  Future<bool>? _renewing;

  /// What the library says about the person, as of now.
  Taste _taste() => Taste(
    heard: [for (final e in store.listens()) Stamped(TrackRef.of(e.track), e.at.millisecondsSinceEpoch)],
    liked: [for (final e in store.likedEntries()) Stamped(TrackRef.of(e.track), e.at.millisecondsSinceEpoch)],
    skipped: [for (final e in store.skipped()) Stamped(TrackRef.of(e.track), e.at.millisecondsSinceEpoch)],
    now: _now(),
  );

  Blocklist _blocklist() {
    final blocked = store.blocked();
    return Blocklist(
      songs: {for (final b in blocked) if (b.kind == song) b.key},
      artists: {for (final b in blocked) if (b.kind == artist) b.key},
    );
  }

  /// The lists kept for [seeds], the best loved seed first; a seed without a list is left out.
  List<List<TrackRef>> _kept(List<String> seeds) => [
    for (final seed in seeds)
      if (store.cachedSuggestions(seed) case final kept?) kept.tracks,
  ];

  /// Songs to offer, from what is kept; nothing until there are seeds and their lists were fetched once.
  List<TrackRef> forYou({int limit = forYouCount}) {
    final taste = _taste();
    final block = _blocklist();
    final seeds = taste.seeds(seedCount, block);
    return Suggestions.compose(_kept(seeds), taste, block, _known(seeds), limit);
  }

  /// Songs by artists the person does not know yet, from what is kept: something new to try.
  List<TrackRef> discover({int limit = discoverCount}) {
    final taste = _taste();
    final block = _blocklist();
    final seeds = taste.seeds(seedCount, block);
    return Suggestions.discover(_kept(seeds), taste, block, _known(seeds), limit);
  }

  /// Fetches again the lists of the seeds whose list is missing or older than [freshMs], or all of them with [force].
  /// One failed seed does not stop the others; what was kept for it stays. Returns whether anything changed.
  Future<bool> renew({required bool force}) {
    // One renewal at a time: a second ask waits for the first and then looks again
    final running = _renewing ?? Future.value(false);
    late final Future<bool> tracked;
    tracked = running.then((_) => _renew(force)).whenComplete(() {
      if (identical(_renewing, tracked)) _renewing = null;
    });
    return _renewing = tracked;
  }

  Future<bool> _renew(bool force) async {
    final taste = _taste();
    final block = _blocklist();
    final seeds = taste.seeds(seedCount, block);
    var changed = false;
    for (final seed in seeds) {
      if (await _fetch(seed, force)) changed = true;
    }
    // The lists behind the mixes for each time of day stay too, so they are there when that time comes
    store.keepSuggestionsFor([
      ...seeds,
      for (final bucket in Taste.buckets) for (final t in taste.contextSeeds(bucket, block)) t.videoId,
    ]);
    return changed;
  }

  /// Fetches the radio of [seed] and keeps it, unless a fresh one is kept (and not [force]d). False when nothing changed.
  Future<bool> _fetch(String seed, bool force) async {
    final kept = store.cachedSuggestions(seed);
    if (!force && kept != null && _now() - kept.fetchedAt < freshMs) return false;
    try {
      store.putSuggestions(seed, [for (final t in await radio(seed)) if (Suggestions.isSong(t)) t], _now());
      return true;
    } on Object catch (e) {
      _log('could not fetch suggestions for $seed: $e');
      return false;
    }
  }

  /// The songs kept for each seed, for the screens that say "because you listened to".
  List<(String, List<TrackRef>)> seedLists() {
    final seeds = _taste().seeds(seedCount, _blocklist());
    return [
      for (final seed in seeds)
        if (store.cachedSuggestions(seed) case final kept?) (seed, kept.tracks),
    ];
  }

  /// A mix for this time of day: the songs the person plays at this hour, then what YouTube lists beside them. The part
  /// of the day and the songs, empty until enough was heard at this hour to say anything. A list that was not kept yet
  /// is fetched, so this may need the network.
  Future<(String, List<TrackRef>)> contextMix({int limit = contextCount}) async {
    final taste = _taste();
    final block = _blocklist();
    final bucket = Taste.bucketOf(DateTime.fromMillisecondsSinceEpoch(_now()).hour);
    final seeds = taste.contextSeeds(bucket, block);
    if (seeds.isEmpty) return (bucket, const <TrackRef>[]);
    for (final seed in seeds) {
      await _fetch(seed.videoId, false);
    }
    final ids = seeds.map((t) => t.videoId).toList();
    final songs = [...seeds, ...Suggestions.compose(_kept(ids), taste, block, ids.toSet(), limit)];
    return (bucket, songs.take(limit).toList());
  }

  /// Up to [count] songs to carry on with after [videoId], other than [exclude], what was heard lately and what the
  /// person does not want: the radio YouTube Music makes of the song. Needs the network.
  Future<List<TrackRef>> after(String videoId, Set<String> exclude, int count) async {
    final taste = _taste();
    final block = _blocklist();
    return Suggestions.mix(
      [await radio(videoId)],
      {...exclude, videoId, ...store.heardSince(_now() - _recentMs)},
      count,
      (t) => Suggestions.welcome(t, taste, block),
    );
  }

  /// Songs not worth offering: the seeds themselves, those liked and those heard this week.
  Set<String> _known(List<String> seeds) => {...seeds, ...store.likedIds(), ...store.heardSince(_now() - _recentMs)};

  static const forYouCount = 30;
  static const discoverCount = 20;
  static const contextCount = 20;
  static const seedCount = 8;
  static const freshMs = 12 * 60 * 60 * 1000;
  static const song = 'song';
  static const artist = 'artist';
  static const _recentMs = 7 * 24 * 60 * 60 * 1000;
}
