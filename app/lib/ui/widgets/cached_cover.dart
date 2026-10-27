import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A cover from the internet kept on the phone: fetched once, then read from a file, instead of fetched again every
/// time the app starts or the memory cache lets it go. Every fetch wakes the radio and every cover that scrolls in
/// was a download; a file is neither.
@immutable
class CachedCover extends ImageProvider<CachedCover> {
  const CachedCover(this.url);

  final String url;

  @override
  Future<CachedCover> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CachedCover key, ImageDecoderCallback decode) {
    // In a browser the browser keeps pictures itself; where fetching is made up (the tests), the picture is fetched
    // as it always was, and no file is kept. Without CORS headers the browser still shows a picture, just not as pixels.
    if (kIsWeb) {
      final image = NetworkImage(url, webHtmlElementStrategy: strategyFor(url));
      return image.loadImage(image, decode);
    }
    if (HttpOverrides.current != null) {
      return NetworkImage(url).loadImage(NetworkImage(url), decode);
    }
    return MultiFrameImageStreamCompleter(
      codec: _codec(decode),
      scale: 1,
      debugLabel: url,
    );
  }

  /// How a browser may show [url]. A failed fetch makes the browser retry in an `<img>` element, which draws the body
  /// of an error page as if it were the picture. YouTube's thumbnail host allows CORS yet answers a size a video does
  /// not have (`maxresdefault`) with a 404 whose body is a 120x90 grey picture: through `<img>` that is a blur
  /// stretched over the cover, and the fall back to the video's own picture never happens. For that host a failure
  /// has to stay a failure.
  @visibleForTesting
  static WebHtmlElementStrategy strategyFor(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == 'ytimg.com' || host.endsWith('.ytimg.com')
        ? WebHtmlElementStrategy.never
        : WebHtmlElementStrategy.fallback;
  }

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async {
    final bytes = await CoverFiles.bytes(url);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) => other is CachedCover && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'CachedCover("$url")';
}

/// The files of [CachedCover], in the app's cache folder (which the system may empty when it needs the room), kept
/// under [_limit] bytes by dropping the oldest when the app starts. Without a folder, or with one that cannot be used,
/// the files are lost, never the pictures: they are then fetched as if there were none.
abstract final class CoverFiles {
  static const _limit = 120 << 20;

  /// Covers being read or fetched, so that two sizes of one cover make one download.
  static final _pending = <String, Future<Uint8List>>{};
  static Future<Directory>? _folder;

  /// What a cover for a song from a file on this phone ([localPrefix]) is read with: the picture inside the file.
  static Future<Uint8List?> Function(String videoId)? localCover;

  /// What a cover address starts with when the picture is inside a music file; the rest is the id of the song.
  static const localPrefix = 'sapoche-local:';

  /// Songs whose file has no picture, so that a list does not ask the phone again at every redraw.
  static final _noPicture = <String>{};

  /// Keeps the covers in a folder inside [cache], the cache folder of the app as the native side names it.
  static void useFolder(String? cache) {
    _folder = cache == null ? null : _open(cache);
  }

  static Future<Uint8List> bytes(String url) => _pending.putIfAbsent(
    url,
    // A block, not an arrow: what `remove` gives back is this very future, which it would then wait for
    () => _read(url).whenComplete(() {
      _pending.remove(url);
    }),
  );

  static Future<Uint8List> _read(String url) async {
    Directory? folder;
    try {
      folder = await _folder;
    } on Object {
      // A folder that could not be made
    }
    if (folder == null) return _fetch(url);
    final file = File('${folder.path}/${_name(url)}');
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      // Not kept yet
    }
    final bytes = await _fetch(url);
    try {
      // Written aside and moved into place, so that a file half written is never read as a picture
      final part = File('${file.path}.part');
      await part.writeAsBytes(bytes);
      await part.rename(file.path);
    } on FileSystemException {
      // Kept another time
    }
    return bytes;
  }

  static Future<Directory> _open(String cache) async {
    final folder = await Directory('$cache/covers').create(recursive: true);
    unawaited(_trim(folder));
    return folder;
  }

  /// Drops the oldest files until the rest fit in [_limit].
  static Future<void> _trim(Directory folder) async {
    try {
      final files = <(File, FileStat)>[];
      await for (final entry in folder.list()) {
        if (entry is File) files.add((entry, await entry.stat()));
      }
      var total = files.fold<int>(0, (sum, f) => sum + f.$2.size);
      if (total <= _limit) return;
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (file, stat) in files) {
        if (total <= _limit) break;
        await file.delete();
        total -= stat.size;
      }
    } on FileSystemException {
      // Tried again at the next start
    }
  }

  static Future<Uint8List> _fromFile(String videoId) async {
    final bytes = _noPicture.contains(videoId)
        ? null
        : await localCover?.call(videoId);
    if (bytes == null || bytes.isEmpty) {
      _noPicture.add(videoId);
      throw StateError('$videoId has no picture in its file');
    }
    return bytes;
  }

  static final _client = HttpClient()..autoUncompress = false;

  static Future<Uint8List> _fetch(String url) async {
    if (url.startsWith(localPrefix)) return _fromFile(url.substring(localPrefix.length));
    final uri = Uri.parse(url);
    final response = await (await _client.getUrl(uri)).close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw NetworkImageLoadException(
        statusCode: response.statusCode,
        uri: uri,
      );
    }
    final bytes = await consolidateHttpClientResponseBytes(response);
    if (bytes.isEmpty) throw StateError('$url is an empty file');
    return bytes;
  }

  /// A file name for [url]: its 64-bit FNV-1a hash.
  @visibleForTesting
  static String fileName(String url) => _name(url);

  static String _name(String url) {
    // Parsed, as dart2js refuses a literal this large; only the apps keep cover files
    var hash = int.parse('-3750763034362895579'); // 0xcbf29ce484222325
    for (final unit in url.codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
    }
    return hash.toUnsigned(64).toRadixString(16);
  }
}
