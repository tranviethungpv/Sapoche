import 'package:flutter/widgets.dart' show StringCharacters;

import 'models.dart';

/// What a chat message carries besides words, read from the `x` of [ChatMessage]. The kinds are the ones every platform
/// writes; a message whose kind is not known here (`null`) is shown by its words, which the sender wrote to stand in for it.
sealed class ChatExtra {
  const ChatExtra();

  /// The extra of [message], or null for plain words and for a kind this app does not know.
  static ChatExtra? of(ChatMessage message) {
    final x = message.x;
    if (x == null) return null;
    try {
      return switch (x['k']) {
        SongExtra.kind => SongExtra.fromJson(x),
        AlbumExtra.kind => AlbumExtra.fromJson(x),
        StickerExtra.kind => StickerExtra.fromJson(x),
        _ => null,
      };
    } on Object {
      return null; // a message of another version, or a damaged one: its words stand in
    }
  }

  /// The `x` to send.
  Map<String, Object?> toJson();
}

/// A song of YouTube Music shared in the chat: `{k:"song", v, ti, ar, d, art?}`.
class SongExtra extends ChatExtra {
  const SongExtra({required this.videoId, required this.title, required this.artist, required this.durMs, this.art});

  static const kind = 'song';

  final String videoId;
  final String title;
  final String artist;
  final int durMs;

  /// The cover's address.
  final String? art;

  factory SongExtra.fromTrack(Track track) => SongExtra(
    videoId: track.videoId,
    title: track.title,
    artist: track.artist,
    durMs: track.durMs,
    art: track.thumb,
  );

  factory SongExtra.fromJson(Map<String, dynamic> json) {
    final videoId = json['v'] as String;
    if (!isVideoId(videoId)) throw const FormatException('not the id of a YouTube video');
    final art = json['art'] as String?;
    return SongExtra(
      videoId: videoId,
      title: json['ti'] as String? ?? '',
      artist: json['ar'] as String? ?? '',
      durMs: (json['d'] as num?)?.toInt() ?? 0,
      // Only a picture from the internet: whatever else the field holds is not fetched
      art: art != null && art.startsWith('https://') ? art : null,
    );
  }

  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  /// Whether [id] is the id of a YouTube video: a song from a file on the phone has none, and cannot be sent.
  static bool isVideoId(String id) => _videoId.hasMatch(id);

  /// What apps that do not know the song show in its place: the song and a link that opens it.
  String get standIn {
    String clip(String text, int max) => text.characters.length > max ? '${text.characters.take(max)}…' : text;
    final by = artist.isEmpty ? '' : ' · ${clip(artist, 100)}';
    return '🎵 ${clip(title, 200)}$by  https://music.youtube.com/watch?v=$videoId';
  }

  Track get track => Track(videoId: videoId, title: title, artist: artist, durMs: durMs, thumb: art);

  @override
  Map<String, Object?> toJson() => {'k': kind, 'v': videoId, 'ti': title, 'ar': artist, 'd': durMs, 'art': ?art};
}

/// One picture of an album: where it is, how to open it and what to show while it loads.
class AlbumItem {
  const AlbumItem({
    required this.m,
    required this.key,
    required this.sha,
    required this.mime,
    required this.w,
    required this.h,
    required this.n,
    required this.th,
    this.d = 0,
  });

  /// The id of the file in the room's bucket.
  final String m;

  /// The key of the file, base64url (32 bytes).
  final String key;

  /// SHA-256 of the file as it is in the bucket, base64url.
  final String sha;

  /// `image/jpeg`, `image/gif` or `image/webp`; `video/mp4` for a video (see [AlbumExtra.isVideo]).
  final String mime;
  final int w;
  final int h;

  /// Bytes of the file in the bucket.
  final int n;

  /// A tiny JPEG (about 20 px) as base64, shown blurred until the picture is here.
  final String th;

  /// How long a video is, in milliseconds; 0 for a picture.
  final int d;

  bool get animated => mime == 'image/gif' || mime == 'image/webp';
  bool get isVideo => mime.startsWith('video/');

  /// Width over height, kept within what a bubble can show.
  double get aspect => h <= 0 || w <= 0 ? 1 : (w / h).clamp(0.5, 2.0);

  factory AlbumItem.fromJson(Map<String, dynamic> json) => AlbumItem(
    m: json['m'] as String,
    key: json['key'] as String,
    sha: json['sha'] as String,
    mime: json['mime'] as String? ?? 'image/jpeg',
    w: (json['w'] as num?)?.toInt() ?? 0,
    h: (json['h'] as num?)?.toInt() ?? 0,
    n: (json['n'] as num?)?.toInt() ?? 0,
    th: json['th'] as String? ?? '',
    d: (json['d'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toJson() => {
    'm': m,
    'key': key,
    'sha': sha,
    'mime': mime,
    'w': w,
    'h': h,
    'n': n,
    'th': th,
    if (d > 0) 'd': d,
  };
}

/// Pictures sent together (one to [maxItems]), with a caption they share: `{k:"album", items, cap?}`. A video is an album of
/// two: the video and, after it, its poster (a picture), see [isVideo].
class AlbumExtra extends ChatExtra {
  const AlbumExtra({required this.items, this.caption});

  static const kind = 'album';
  static const maxItems = 10;

  final List<AlbumItem> items;
  final String? caption;

  /// A video and its poster, not pictures.
  bool get isVideo => items.first.isVideo;
  AlbumItem get video => items.first;
  AlbumItem get poster => items.last;

  factory AlbumExtra.fromJson(Map<String, dynamic> json) {
    final items = [for (final i in json['items'] as List<dynamic>) AlbumItem.fromJson(i as Map<String, dynamic>)];
    if (items.isEmpty || items.length > maxItems) throw const FormatException('an album holds 1 to 10 pictures');
    if (items.first.isVideo && (items.length != 2 || items.last.isVideo)) {
      throw const FormatException('a video is a video and its poster');
    }
    final cap = json['cap'] as String?;
    return AlbumExtra(items: items, caption: cap == null || cap.isEmpty ? null : cap);
  }

  @override
  Map<String, Object?> toJson() => {
    'k': kind,
    'items': [for (final i in items) i.toJson()],
    if (caption != null && caption!.isNotEmpty) 'cap': caption,
  };
}

/// A sticker of a pack: `{k:"stk", p, s, e}`; [emoji] is the one it stands for, shown where the pack is not at hand.
class StickerExtra extends ChatExtra {
  const StickerExtra({required this.pack, required this.sticker, required this.emoji});

  static const kind = 'stk';

  final String pack;
  final String sticker;
  final String emoji;

  factory StickerExtra.fromJson(Map<String, dynamic> json) =>
      StickerExtra(pack: json['p'] as String, sticker: json['s'] as String, emoji: json['e'] as String? ?? '');

  @override
  Map<String, Object?> toJson() => {'k': kind, 'p': pack, 's': sticker, 'e': emoji};
}
