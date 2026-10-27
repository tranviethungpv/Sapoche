import 'dart:collection' show Queue;
import 'dart:math';

import '../models.dart';
import 'wire.dart';

/// A song with the moment something happened to it: it was heard, liked or left after a few seconds.
class Stamped {
  const Stamped(this.track, this.at);

  final TrackRef track;
  final int at;
}

/// Songs and artists the person asked not to be offered, by video id and by [Taste.artistKey].
class Blocklist {
  const Blocklist({this.songs = const {}, this.artists = const {}});

  final Set<String> songs;
  final Set<String> artists;

  bool allows(TrackRef track) => !songs.contains(track.videoId) && !artists.contains(Taste.artistKey(track.artist));
}

/// What the listening says about a person's taste: how much each song and each artist is loved, from what was heard (a
/// point each), liked (more) and left after a few seconds (less than nothing), all counting for less as they get older.
/// Nothing leaves the browser and nothing needs the network; it only reads what the library keeps. Dart counterpart of
/// `Taste.kt` and `Taste.swift`.
class Taste {
  Taste({
    required List<Stamped> heard,
    required List<Stamped> liked,
    required List<Stamped> skipped,
    required this.now,
    int Function(int at)? hourOf,
  }) : _heard = heard,
       _hourOf = hourOf ?? _localHour {
    void add(List<Stamped> list, double weight, int halfLifeMs) {
      for (final s in list) {
        final value = weight * _decay(now - s.at, halfLifeMs);
        _songs.update(s.track.videoId, (v) => v + value, ifAbsent: () => value);
        _artists.update(artistKey(s.track.artist), (v) => v + value, ifAbsent: () => value);
        _tracks.putIfAbsent(s.track.videoId, () => s.track);
      }
    }

    add(heard, _heardWeight, _playHalfLifeMs);
    add(liked, _likedWeight, _likeHalfLifeMs);
    add(skipped, _skippedWeight, _playHalfLifeMs);
  }

  final List<Stamped> _heard;
  final int now;
  final int Function(int at) _hourOf;
  final _songs = <String, double>{};
  final _artists = <String, double>{};
  final _tracks = <String, TrackRef>{};

  /// The artist has been listened to, or liked, enough to be known.
  bool knows(String artist) => (_artists[artistKey(artist)] ?? 0.0) >= known;

  /// The artist's songs were left lately more than they were heard.
  bool dislikes(String artist) => (_artists[artistKey(artist)] ?? 0.0) <= disliked;

  /// The songs suggestions are built from, up to [count]: the best loved, one per artist where there are enough artists,
  /// so the mix is not all one voice. A song of an artist that is disliked or blocked is never one.
  List<String> seeds(int count, [Blocklist block = const Blocklist()]) {
    final ranked = <(TrackRef, double)>[];
    for (final e in _songs.entries) {
      // A song from a file on the device has no radio to ask for: it tells what is liked, but is never a seed
      if (e.value < minSeed || e.key.startsWith(Track.localPrefix)) continue;
      final track = _tracks[e.key];
      if (track != null && block.allows(track) && !dislikes(track.artist)) ranked.add((track, e.value));
    }
    ranked.sort((a, b) {
      final byValue = b.$2.compareTo(a.$2);
      return byValue != 0 ? byValue : a.$1.videoId.compareTo(b.$1.videoId);
    });
    final picked = <String, TrackRef>{};
    final perArtist = <String, int>{};
    for (var cap = 1; cap <= 2; cap++) {
      for (final (track, _) in ranked) {
        if (picked.length >= count) break;
        final key = artistKey(track.artist);
        if (picked.containsKey(track.videoId) || (perArtist[key] ?? 0) >= cap) continue;
        picked[track.videoId] = track;
        perArtist.update(key, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return picked.keys.toList();
  }

  /// The songs the person plays at this time of day ([bucket], see [bucketOf]), most played first, up to [count], one per
  /// artist; empty until enough was heard at that time for it to mean something.
  List<TrackRef> contextSeeds(String bucket, [Blocklist block = const Blocklist(), int count = 2]) {
    final since = now - _contextWindowMs;
    final inBucket = _heard.where((s) => s.at >= since && bucketOf(_hourOf(s.at)) == bucket).toList();
    if (inBucket.length < minContext) return const [];
    final plays = <String, double>{};
    final seen = <String, TrackRef>{};
    for (final s in inBucket) {
      final value = _decay(now - s.at, _playHalfLifeMs);
      plays.update(s.track.videoId, (v) => v + value, ifAbsent: () => value);
      seen.putIfAbsent(s.track.videoId, () => s.track);
    }
    final ids = plays.keys.toList()
      ..sort((a, b) {
        final byPlays = plays[b]!.compareTo(plays[a]!);
        return byPlays != 0 ? byPlays : a.compareTo(b);
      });
    final picked = <TrackRef>[];
    final artistsTaken = <String>{};
    for (final id in ids) {
      final track = seen[id]!;
      if (picked.length >= count) break;
      if (id.startsWith(Track.localPrefix) ||
          !block.allows(track) ||
          (_songs[id] ?? 0.0) <= 0.0 ||
          !artistsTaken.add(artistKey(track.artist))) {
        continue;
      }
      picked.add(track);
    }
    return picked;
  }

  static const _heardWeight = 1.0;
  static const _likedWeight = 2.5;
  static const _skippedWeight = -1.2;
  static const _playHalfLifeMs = 21 * 24 * 60 * 60 * 1000;
  static const _likeHalfLifeMs = 90 * 24 * 60 * 60 * 1000;
  static const known = 0.5;
  static const disliked = -2.0;
  static const minSeed = 0.5;
  static const _contextWindowMs = 60 * 24 * 60 * 60 * 1000;
  static const minContext = 5;

  /// The parts of a day, for the mix that suits the time: morning, afternoon, evening and night.
  static const buckets = ['morning', 'afternoon', 'evening', 'night'];

  static String bucketOf(int hour) => switch (hour) {
    >= 5 && <= 10 => 'morning',
    >= 11 && <= 16 => 'afternoon',
    >= 17 && <= 21 => 'evening',
    _ => 'night',
  };

  static double _decay(int ageMs, int halfLifeMs) => pow(0.5, max(ageMs, 0) / halfLifeMs).toDouble();

  static int _localHour(int at) => DateTime.fromMillisecondsSinceEpoch(at).hour;

  static final _channelSuffix = RegExp(r'\s*(?:-\s*topic|vevo|official(?:\s+channel)?)$', caseSensitive: false);
  // `\b` knows only ASCII letters in a browser, so "và" is told by the spaces around it instead
  static final _artistSplit = RegExp(r'\s*(?:,|&|\bx\b|\bfeat\.?|\bft\.?|\s+và\s+|\band\b)\s*', caseSensitive: false);
  static final _punctuation = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  /// The first artist of a credit like "A, B & C" as it is written, without "- Topic", "VEVO" or "Official".
  static String artistLabel(String credit) {
    final text = credit.trim().replaceAll(_channelSuffix, '');
    final split = _artistSplit.firstMatch(text);
    final first = split == null ? text : text.substring(0, split.start);
    return first.replaceAll(_channelSuffix, '').trim();
  }

  /// What tells one artist from another: the first artist of a credit in plain lower-case letters (as the UI does).
  static String artistKey(String credit) => artistLabel(credit).toLowerCase().replaceAll(_punctuation, ' ').trim();
}

/// Turns the songs YouTube lists beside a few seed songs into one list worth offering. YouTube's related lists hold
/// hour-long mixes and full albums beside songs, and songs the person already knows.
abstract final class Suggestions {
  /// Songs shorter or longer than this are left out: what is left is mostly music.
  static const minMs = 60000;
  static const maxMs = 600000;

  static bool isSong(TrackRef track) => track.durMs >= minMs && track.durMs <= maxMs;

  /// One list from several [lists], taking a song from each in turn so no seed crowds out the others. Songs in
  /// [exclude], repeats, non-songs and what [allow] refuses are dropped. At most [limit] come back.
  static List<TrackRef> mix(
    List<List<TrackRef>> lists,
    Set<String> exclude,
    int limit, [
    bool Function(TrackRef track)? allow,
  ]) {
    final seen = {...exclude};
    final result = <TrackRef>[];
    final queues = [
      for (final list in lists) list.where((t) => isSong(t) && (allow?.call(t) ?? true)).toList(),
    ];
    final at = List.filled(queues.length, 0);
    bool anyLeft() {
      for (var i = 0; i < queues.length; i++) {
        if (at[i] < queues[i].length) return true;
      }
      return false;
    }

    while (result.length < limit && anyLeft()) {
      for (var i = 0; i < queues.length; i++) {
        while (at[i] < queues[i].length) {
          final track = queues[i][at[i]++];
          if (!seen.add(track.videoId)) continue;
          result.add(track);
          break;
        }
        if (result.length >= limit) break;
      }
    }
    return result;
  }

  /// At most this many songs of one artist in a list of suggestions.
  static const maxPerArtist = 2;

  /// Of every ten songs, these come from artists the person does not know yet (the rest from ones they do).
  static const _newArtistSlots = {2, 5, 8};

  /// What the person should be offered, or nothing from artists they asked not to hear or left again and again.
  static bool welcome(TrackRef track, Taste taste, Blocklist block) =>
      isSong(track) && block.allows(track) && !taste.dislikes(track.artist);

  /// The suggestions of the seeds ([lists], best loved seed first) as one list: songs by artists the person knows, with a
  /// few by artists they do not know in between, so the list is mostly what they like and a little of what they might.
  /// Songs in [exclude] and what is not [welcome] are left out, and no artist comes more than [maxPerArtist] times. At
  /// most [limit] come back.
  static List<TrackRef> compose(
    List<List<TrackRef>> lists,
    Taste taste,
    Blocklist block,
    Set<String> exclude,
    int limit,
  ) {
    final welcomed = [for (final list in lists) list.where((t) => welcome(t, taste, block)).toList()];
    final known = Queue.of(_turns([for (final list in welcomed) list.where((t) => taste.knows(t.artist)).toList()]));
    final fresh = Queue.of(_turns([for (final list in welcomed) list.where((t) => !taste.knows(t.artist)).toList()]));
    final seen = {...exclude};
    final perArtist = <String, int>{};
    TrackRef? take(Queue<TrackRef> queue) {
      while (queue.isNotEmpty) {
        final track = queue.removeFirst();
        final artist = Taste.artistKey(track.artist);
        if (seen.contains(track.videoId) || (perArtist[artist] ?? 0) >= maxPerArtist) continue;
        seen.add(track.videoId);
        perArtist.update(artist, (n) => n + 1, ifAbsent: () => 1);
        return track;
      }
      return null;
    }

    final result = <TrackRef>[];
    while (result.length < limit) {
      final wantFresh = _newArtistSlots.contains(result.length % 10);
      final track = wantFresh ? take(fresh) ?? take(known) : take(known) ?? take(fresh);
      if (track == null) break;
      result.add(track);
    }
    return result;
  }

  /// Only the songs by artists the person does not know yet, a few of each artist: something new to try.
  static List<TrackRef> discover(
    List<List<TrackRef>> lists,
    Taste taste,
    Blocklist block,
    Set<String> exclude,
    int limit,
  ) {
    final fresh = [
      for (final list in lists) list.where((t) => welcome(t, taste, block) && !taste.knows(t.artist)).toList(),
    ];
    final seen = {...exclude};
    final artists = <String>{};
    return _turns(fresh).where((t) => seen.add(t.videoId) && artists.add(Taste.artistKey(t.artist))).take(limit).toList();
  }

  /// The lists read in turns, one song from each at a time.
  static List<TrackRef> _turns(List<List<TrackRef>> lists) {
    final result = <TrackRef>[];
    for (var i = 0; lists.any((l) => i < l.length); i++) {
      for (final list in lists) {
        if (i < list.length) result.add(list[i]);
      }
    }
    return result;
  }
}
