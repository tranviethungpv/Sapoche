import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'backend.dart';
import 'chat_extra.dart';
import 'media_crypto.dart';
import 'models.dart';
import 'video_probe.dart';

/// A photo as the person picked it: its bytes untouched, and the name of the file.
class PickedPhoto {
  const PickedPhoto(this.bytes, this.name);

  final Uint8List bytes;
  final String name;
}

/// Why a picked photo cannot go in an album.
sealed class PhotoError implements Exception {
  const PhotoError(this.name);

  /// The name of the file.
  final String name;
}

/// A GIF or an animated WebP of more than [ChatMedia.maxAnimatedBytes]: it is sent as it is, so it cannot be made smaller.
class PhotoTooLarge extends PhotoError {
  const PhotoTooLarge(super.name);

  @override
  String toString() => 'PhotoTooLarge($name)';
}

/// Bytes that are no picture this app can read.
class PhotoUnreadable extends PhotoError {
  const PhotoUnreadable(super.name);

  @override
  String toString() => 'PhotoUnreadable($name)';
}

/// A video that cannot be squeezed under [ChatMedia.maxVideoBytes]: too long for that, or (in a browser, which does not
/// squeeze) bigger than it already.
class VideoTooLarge extends PhotoError {
  const VideoTooLarge(super.name, {this.squeezable = true});

  /// The device could squeeze videos, and this one is too long even so; false in a browser, where it is not tried.
  final bool squeezable;

  @override
  String toString() => 'VideoTooLarge($name)';
}

/// A video this device cannot read (a format it has no decoder for, or a damaged file).
class VideoUnreadable extends PhotoError {
  const VideoUnreadable(super.name);

  @override
  String toString() => 'VideoUnreadable($name)';
}

/// A video as the person picked it: a file on the phone, or its bytes where there are no files (a browser).
class PickedVideo {
  const PickedVideo({this.path, this.bytes, required this.name});

  final String? path;
  final Uint8List? bytes;
  final String name;
}

/// A video of the room ready to be played: a file on a phone (named as a player wants it), the bytes in a browser.
class VideoSource {
  const VideoSource({this.path, this.bytes});

  final String? path;
  final Uint8List? bytes;
}

/// A photo ready to go: what is sent, sealed, and what the bubble shows meanwhile.
class PreparedPhoto {
  const PreparedPhoto({
    required this.name,
    required this.bytes,
    required this.mime,
    required this.w,
    required this.h,
    required this.th,
    required this.sealed,
    this.durMs = 0,
  });

  final String name;

  /// The picture as it is sent (and so as the others see it): upright, with nothing of the camera in it. Also the preview.
  final Uint8List bytes;

  /// `image/jpeg`, `image/gif` or `image/webp`.
  final String mime;
  final int w;
  final int h;

  /// A tiny JPEG as plain base64, see [AlbumItem.th].
  final String th;

  /// [bytes] under a key of their own.
  final SealedFile sealed;

  /// How long a video is, in milliseconds; 0 for a picture.
  final int durMs;

  bool get animated => mime == 'image/gif' || mime == 'image/webp';
  bool get isVideo => mime.startsWith('video/');
}

/// What [ChatMedia.prepare] made of a batch: the photos that are ready, in the order picked, and the ones it refused.
class PrepareResult {
  const PrepareResult(this.photos, this.refused);

  final List<PreparedPhoto> photos;
  final List<PhotoError> refused;
}

enum FileState { waiting, uploading, done, failed }

/// How an upload ended: the [album] to send, or the [error] that stopped it. The error is the room's own code from
/// [MediaTickets] (`media_full`, `media_limit`, `media_too_big`, `media_unavailable`, `offline`) or
/// [AlbumUpload.fileFailed] when the room took the tickets but some file did not go up.
class UploadOutcome {
  const UploadOutcome.sent(AlbumExtra this.album) : error = null;
  const UploadOutcome.failed(String this.error) : album = null;

  final AlbumExtra? album;
  final String? error;
}

/// An album on its way up: its photos and how far each has got. It listens like any [ChangeNotifier]; the bubble shows
/// [photos] (the previews) with [done] of [total], and [error] once it stopped.
class AlbumUpload extends ChangeNotifier {
  AlbumUpload._(this._backend, this._store, this.photos, this.caption)
    : _sealed = [for (final p in photos) p.sealed],
      _states = List.filled(photos.length, FileState.waiting),
      _tickets = List.filled(photos.length, null),
      _ticketAt = List.filled(photos.length, null),
      _items = List.filled(photos.length, null);

  /// [error] when some files went up and others did not; [retryFailed] tries those again.
  static const fileFailed = 'upload_failed';

  /// Files put up at the same time.
  static const parallel = 3;

  /// A ticket is good for 10 minutes; one older than this is asked for again.
  static const ticketLife = Duration(minutes: 9);

  final Backend _backend;
  final void Function(String m, Uint8List bytes) _store;
  final List<PreparedPhoto> photos;
  final String? caption;

  final List<SealedFile?> _sealed;
  final List<FileState> _states;
  final List<MediaTicket?> _tickets;
  final List<DateTime?> _ticketAt;
  final List<AlbumItem?> _items;

  /// The time, replaced by the tests.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  Future<UploadOutcome>? _running;
  bool _released = false;
  String? _error;
  AlbumExtra? _album;

  List<FileState> get states => List.unmodifiable(_states);
  int get total => photos.length;
  int get done => _states.where((s) => s == FileState.done).length;

  /// Why it stopped, or null while it goes on or when it went through.
  String? get error => _error;

  /// The album to send, once every file is up.
  AlbumExtra? get album => _album;

  /// It was cancelled, or its bytes were let go: it cannot go on.
  bool get released => _released;

  bool get busy => _running != null;

  /// Puts every file up. [onProgress] hears (done, total) each time a file is up.
  Future<UploadOutcome> upload({void Function(int done, int total)? onProgress}) =>
      _running ??= _run(onProgress).whenComplete(() => _running = null);

  /// Tries the files that failed again (and the ones not yet tried), with fresh tickets if the old ones are too old.
  Future<UploadOutcome> retryFailed({void Function(int done, int total)? onProgress}) => upload(onProgress: onProgress);

  /// Lets go of the bytes that were kept for a retry. What is not up yet is never sent.
  void release() {
    _released = true;
    for (var i = 0; i < _sealed.length; i++) {
      _sealed[i] = null;
    }
  }

  Future<UploadOutcome> _run(void Function(int done, int total)? onProgress) async {
    if (_released) return const UploadOutcome.failed(fileFailed);
    final album = _album;
    if (album != null) return UploadOutcome.sent(album);
    _error = null;
    final todo = [
      for (var i = 0; i < photos.length; i++)
        if (_states[i] != FileState.done) i,
    ];
    final now = clock();
    final stale = [
      for (final i in todo)
        if (_tickets[i] == null || now.difference(_ticketAt[i]!) >= ticketLife) i,
    ];
    if (stale.isNotEmpty) {
      MediaTickets answer;
      try {
        answer = await _backend.mediaTickets([for (final i in stale) _sealed[i]!.file.length]);
      } on Object {
        answer = const MediaTickets.refused('offline');
      }
      if (_released) return const UploadOutcome.failed(fileFailed);
      if (answer.granted && answer.tickets.length != stale.length) {
        answer = const MediaTickets.refused('media_unavailable');
      }
      if (!answer.granted) return _stop(answer.error!);
      for (var k = 0; k < stale.length; k++) {
        _tickets[stale[k]] = answer.tickets[k];
        _ticketAt[stale[k]] = now;
      }
    }
    for (final i in todo) {
      _states[i] = FileState.waiting;
    }
    notifyListeners();
    var next = 0;
    Future<void> worker() async {
      while (!_released && next < todo.length) {
        final i = todo[next++];
        _states[i] = FileState.uploading;
        notifyListeners();
        var ok = false;
        try {
          ok = await _backend.uploadMedia(_tickets[i]!, _sealed[i]!.file);
        } on Object {
          // The file is shown as failed, with the way to try again
        }
        if (_released) return;
        _states[i] = ok ? FileState.done : FileState.failed;
        if (ok) {
          final sealed = _sealed[i]!;
          _items[i] = AlbumItem(
            m: _tickets[i]!.m,
            key: sealed.key,
            sha: sealed.sha,
            n: sealed.file.length,
            mime: photos[i].mime,
            w: photos[i].w,
            h: photos[i].h,
            th: photos[i].th,
            d: photos[i].durMs,
          );
          _sealed[i] = null; // nothing to try again
          _store(_tickets[i]!.m, photos[i].bytes);
        }
        notifyListeners();
        onProgress?.call(done, total);
      }
    }

    await Future.wait([for (var k = 0; k < min(parallel, todo.length); k++) worker()]);
    if (_released) return const UploadOutcome.failed(fileFailed);
    if (_states.any((s) => s != FileState.done)) return _stop(fileFailed);
    return UploadOutcome.sent(_album = AlbumExtra(items: [for (final i in _items) i!], caption: caption));
  }

  UploadOutcome _stop(String error) {
    _error = error;
    notifyListeners();
    return UploadOutcome.failed(error);
  }
}

/// The pictures of the chat: makes them ready to send, puts them up, and brings the others' back, decrypted and kept.
class ChatMedia {
  ChatMedia(this._backend);

  final Backend _backend;

  /// The longest side of a picture that is sent; a smaller one is not scaled up.
  static const maxSide = 1280;
  static const jpegQuality = 80;

  /// A GIF or an animated WebP is sent as it is, and so can be no bigger than this.
  static const maxAnimatedBytes = 3 * 1024 * 1024;

  /// The most a video can weigh once squeezed, in bytes (the room takes a file of 10 MiB and a little more).
  static const maxVideoBytes = 10 * 1024 * 1024;

  /// Pictures kept decrypted in memory: this many, and no more bytes than [_memoryBytes].
  static const _memoryCount = 24;
  static const _memoryBytes = 24 * 1024 * 1024;

  static final _safeName = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  // ------------------------------------------------------------------ preparing

  /// Makes [picked] (at most [AlbumExtra.maxItems], in the order picked) ready to send. A photo that cannot be sent is left
  /// out and told in [PrepareResult.refused]. The work is done away from the screen where there is somewhere away.
  static Future<PrepareResult> prepare(List<PickedPhoto> picked) async {
    final photos = <PreparedPhoto>[];
    final refused = <PhotoError>[];
    for (final photo in picked.take(AlbumExtra.maxItems)) {
      PreparedPhoto? made;
      PhotoError? error;
      (made, error) = await compute(_prepareAway, photo);
      if (error is PhotoUnreadable) {
        // A picture the decoders here do not know (HEIF from Google Photos): the system's own decoder may
        final converted = await viaEngine(photo.bytes);
        if (converted != null) {
          final again = await compute(_prepareAway, PickedPhoto(converted, photo.name));
          made = again.$1;
          error = again.$2;
        }
      }
      if (made != null) photos.add(made);
      if (error != null) refused.add(error);
    }
    return PrepareResult(photos, refused);
  }

  /// [bytes] as a PNG of at most [maxSide] px along its longer side, decoded by the engine, which on Android hands the
  /// picture to the system (HEIF, AVIF) and turns it upright. Null when the engine cannot read it either.
  @visibleForTesting
  static Future<Uint8List?> viaEngine(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final wide = descriptor.width >= descriptor.height;
      codec = await descriptor.instantiateCodec(
        targetWidth: wide && descriptor.width > maxSide ? maxSide : null,
        targetHeight: !wide && descriptor.height > maxSide ? maxSide : null,
      );
      image = (await codec.getNextFrame()).image;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } on Object {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  /// Makes [video] ready to send: squeezed to no more than [maxVideoBytes] where the device can (a browser sends what is
  /// small enough already, as it is), with its poster, sealed. Gives back the video and its poster, in this order, as the
  /// two files of an album that is a video; throws a [PhotoError] when it cannot be sent.
  Future<List<PreparedPhoto>> prepareVideo(PickedVideo video, {bool mirror = false}) async {
    final Uint8List bytes;
    final int w, h, durMs;
    final Uint8List posterBytes;
    if (kIsWeb) {
      final raw = video.bytes;
      if (raw == null || raw.isEmpty) throw VideoUnreadable(video.name);
      if (raw.length > maxVideoBytes) throw VideoTooLarge(video.name, squeezable: false);
      final probe = await probeVideo(raw, video.name);
      if (probe == null) throw VideoUnreadable(video.name);
      (bytes, w, h, durMs, posterBytes) = (raw, probe.w, probe.h, probe.durMs, probe.poster);
    } else {
      final path = video.path;
      if (path == null) throw VideoUnreadable(video.name);
      final VideoFile made;
      try {
        made = await _backend.prepareVideo(path, maxVideoBytes, mirror: mirror);
      } on BackendException catch (e) {
        throw switch (e.code) {
          'video_too_big' => VideoTooLarge(video.name),
          _ => VideoUnreadable(video.name),
        };
      }
      final file = File(made.path);
      try {
        bytes = await file.readAsBytes();
      } finally {
        // What native wrote to be read is not kept
        await file.delete().catchError((Object _) => file);
      }
      if (bytes.isEmpty) throw VideoUnreadable(video.name);
      if (bytes.length > maxVideoBytes) throw VideoTooLarge(video.name);
      (w, h, durMs, posterBytes) = (made.w, made.h, made.durMs, made.poster);
    }
    final poster = await prepareOne(PickedPhoto(posterBytes, 'poster.jpg'));
    final sealed = await compute(_sealAway, bytes);
    final thumb = PreparedPhoto(
      name: video.name,
      bytes: bytes,
      mime: 'video/mp4',
      w: w,
      h: h,
      th: poster.th,
      sealed: sealed,
      durMs: durMs,
    );
    return [thumb, poster];
  }

  /// [photo] turned left to right, made ready again: what a selfie needs, since the camera saves it the other way round
  /// from what the preview showed. A moving picture (GIF, animated WebP) is not turned: it is given back as it is.
  static Future<PreparedPhoto> mirror(PreparedPhoto photo) async {
    if (photo.animated || photo.isVideo) return photo;
    final flipped = await compute(_flipAway, photo.bytes);
    if (flipped == null) return photo;
    return prepareOne(PickedPhoto(flipped, photo.name));
  }

  /// The same for one photo; throws a [PhotoError] when it cannot be sent.
  static Future<PreparedPhoto> prepareOne(PickedPhoto photo) async {
    final (made, error) = await compute(_prepareAway, photo);
    if (error != null) throw error;
    return made!;
  }

  // ------------------------------------------------------------------ uploading

  /// An album of [photos] to put up with [AlbumUpload.upload]; the pictures are kept here as soon as they are up.
  AlbumUpload upload(List<PreparedPhoto> photos, {String? caption}) =>
      AlbumUpload._(_backend, remember, photos, caption);

  // ------------------------------------------------------------------ opening and keeping

  final _memory = <String, Uint8List>{};
  var _memorySize = 0;
  final _inflight = <String, Future<Uint8List?>>{};
  Future<Directory?>? _folder;

  /// The picture [item] of [room] as it is to be shown, from what is kept or else fetched, checked and decrypted. Null
  /// when it cannot be fetched or is not what the message says. Callers asking for the same picture share one fetch.
  Future<Uint8List?> open(String room, AlbumItem item) {
    final kept = _recall(item.m);
    if (kept != null) return Future.value(kept);
    return _inflight[item.m] ??= _fetch(room, item).whenComplete(() {
      _inflight.remove(item.m);
    });
  }

  /// The video [item] of [room] ready to be played, fetched and decrypted like a picture; null when it cannot be had.
  Future<VideoSource?> videoSource(String room, AlbumItem item) async {
    if (!_safeName.hasMatch(item.m)) return null;
    final bytes = await open(room, item);
    if (bytes == null) return null;
    // Where there is no cache folder of the app, the temporary one of the system: a player wants a file
    final folder = kIsWeb ? null : await _directory() ?? Directory.systemTemp;
    if (folder == null) return VideoSource(bytes: bytes);
    try {
      // With the name of an MP4: some players go by it
      final file = File('${folder.path}${Platform.pathSeparator}${item.m}.mp4');
      if (!await file.exists() || await file.length() != bytes.length) await file.writeAsBytes(bytes, flush: true);
      return VideoSource(path: file.path);
    } on Object {
      return null;
    }
  }

  /// Keeps [bytes], the decrypted picture [m], so it is not fetched again.
  void remember(String m, Uint8List bytes) {
    _hold(m, bytes);
    unawaited(_write(m, bytes));
  }

  void _hold(String m, Uint8List bytes) {
    final old = _memory.remove(m);
    if (old != null) _memorySize -= old.length;
    _memory[m] = bytes;
    _memorySize += bytes.length;
    while (_memory.length > _memoryCount || (_memorySize > _memoryBytes && _memory.length > 1)) {
      _memorySize -= _memory.remove(_memory.keys.first)!.length;
    }
  }

  Uint8List? _recall(String m) {
    final bytes = _memory.remove(m);
    if (bytes != null) _memory[m] = bytes; // the latest used goes last
    return bytes;
  }

  Future<Uint8List?> _fetch(String room, AlbumItem item) async {
    final onDisk = await _read(item.m);
    if (onDisk != null) {
      _hold(item.m, onDisk);
      return onDisk;
    }
    Uint8List? file;
    try {
      file = await _backend.downloadMedia(room, item.m);
    } on Object {
      return null;
    }
    if (file == null) return null;
    final bytes = await compute(_openAway, (file, item.key, item.sha));
    if (bytes != null) remember(item.m, bytes);
    return bytes;
  }

  /// The folder for the decrypted pictures, inside the app's cache; null in a browser (which keeps the files it fetched
  /// itself) and where the app has no cache folder.
  Future<Directory?> _directory() => _folder ??= () async {
    if (kIsWeb) return null;
    try {
      final base = await _backend.cacheFolder();
      if (base == null) return null;
      return await Directory('$base${Platform.pathSeparator}chat-media').create(recursive: true);
    } on Object {
      return null;
    }
  }();

  Future<Uint8List?> _read(String m) async {
    if (!_safeName.hasMatch(m)) return null;
    try {
      final folder = await _directory();
      if (folder == null) return null;
      final file = File('${folder.path}${Platform.pathSeparator}$m');
      return await file.exists() ? await file.readAsBytes() : null;
    } on Object {
      return null;
    }
  }

  Future<void> _write(String m, Uint8List bytes) async {
    if (!_safeName.hasMatch(m)) return;
    try {
      final folder = await _directory();
      if (folder == null) return;
      final path = '${folder.path}${Platform.pathSeparator}$m';
      // Written aside and moved, so a picture half written is never read
      final part = File('$path.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(path);
    } on Object {
      // Only kept in memory then
    }
  }
}

/// What [ChatMedia.open] does away from the screen: the file opened with its key, or null when it does not check out.
Future<Uint8List?> _openAway((Uint8List, String, String) job) => MediaCrypto.open(job.$1, job.$2, sha: job.$3);

/// [bytes] (a picture) turned left to right as a good JPEG, away from the screen; null when it is not a picture.
Uint8List? _flipAway(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    // Upright first, so that left and right are the ones the person sees
    final upright = img.bakeOrientation(decoded);
    img.flipHorizontal(upright);
    upright.exif = img.ExifData();
    return img.encodeJpg(upright, quality: 92);
  } catch (_) {
    return null;
  }
}

/// [bytes] sealed, away from the screen: sealing ten megabytes takes seconds.
Future<SealedFile> _sealAway(Uint8List bytes) => MediaCrypto.seal(bytes);

/// What [ChatMedia.prepare] does to one photo away from the screen: the photo or the reason it is refused, given back
/// rather than thrown.
Future<(PreparedPhoto?, PhotoError?)> _prepareAway(PickedPhoto photo) async {
  final bytes = photo.bytes;
  final kind = _kindOf(bytes);
  if (kind == null) return (null, PhotoUnreadable(photo.name));
  final keep = kind.animated;
  if (keep && bytes.length > ChatMedia.maxAnimatedBytes) return (null, PhotoTooLarge(photo.name));

  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // The decoders throw all sorts of errors on bytes that are not a picture
    decoded = null;
  }
  // An animated picture that cannot be decoded is still sent as it is, with the size the file says
  if (decoded == null && !keep) return (null, PhotoUnreadable(photo.name));

  final Uint8List sent;
  final int w, h;
  if (keep) {
    sent = bytes;
    (w, h) = decoded == null ? kind.size(bytes) : (decoded.width, decoded.height);
  } else {
    final upright = _flat(_shrunk(img.bakeOrientation(decoded!), ChatMedia.maxSide));
    // Nothing the camera wrote (where it was, what it is) goes with the picture
    upright.exif = img.ExifData();
    sent = img.encodeJpg(upright, quality: ChatMedia.jpegQuality);
    (w, h) = (upright.width, upright.height);
  }
  final thumb = decoded == null ? '' : _thumbnail(decoded);
  final sealed = await MediaCrypto.seal(sent);
  return (PreparedPhoto(name: photo.name, bytes: sent, mime: kind.mime, w: w, h: h, th: thumb, sealed: sealed), null);
}

/// [image] with its longer side at most [side] px.
img.Image _shrunk(img.Image image, int side) {
  if (max(image.width, image.height) <= side) return image;
  return image.width >= image.height
      ? img.copyResize(image, width: side, interpolation: img.Interpolation.average)
      : img.copyResize(image, height: side, interpolation: img.Interpolation.average);
}

/// [image] on white where it is see-through, since a JPEG has no transparency.
img.Image _flat(img.Image image) {
  if (!image.hasAlpha) return image;
  final flat = img.Image(width: image.width, height: image.height);
  img.fill(flat, color: img.ColorRgb8(255, 255, 255));
  return img.compositeImage(flat, image);
}

/// A JPEG of [image] 24 px along its longer side, as plain base64.
String _thumbnail(img.Image image) {
  final upright = _flat(_shrunk(img.bakeOrientation(image), 24));
  upright.exif = img.ExifData();
  return base64.encode(img.encodeJpg(upright, quality: 50));
}

class _Kind {
  const _Kind(this.mime, this.animated, this.size);

  final String mime;
  final bool animated;

  /// The size the file itself says, for when the first frame cannot be decoded.
  final (int, int) Function(Uint8List bytes) size;
}

(int, int) _unknownSize(Uint8List bytes) => (0, 0);

(int, int) _gifSize(Uint8List b) => (b[6] | b[7] << 8, b[8] | b[9] << 8);

(int, int) _webpSize(Uint8List b) {
  // An extended file starts its chunks with VP8X: the canvas is 24 bits each, less one
  if (b.length < 30 || String.fromCharCodes(b, 12, 16) != 'VP8X') return (0, 0);
  return ((b[24] | b[25] << 8 | b[26] << 16) + 1, (b[27] | b[28] << 8 | b[29] << 16) + 1);
}

/// What [bytes] are by their first bytes (the name of the file says nothing); null for what is not a picture the app takes.
_Kind? _kindOf(Uint8List b) {
  if (b.length < 12) return null;
  if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return const _Kind('image/jpeg', false, _unknownSize);
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return const _Kind('image/jpeg', false, _unknownSize);
  }
  final head = String.fromCharCodes(b, 0, 4);
  if (head == 'GIF8') return const _Kind('image/gif', true, _gifSize);
  if (head == 'RIFF' && String.fromCharCodes(b, 8, 12) == 'WEBP') {
    // The animation flag is the second bit of the flags of the VP8X chunk
    final animated = b.length > 20 && String.fromCharCodes(b, 12, 16) == 'VP8X' && (b[20] & 0x02) != 0;
    return _Kind(animated ? 'image/webp' : 'image/jpeg', animated, _webpSize);
  }
  // HEIC and the like, which the system turns into a JPEG when it hands them over; anything the decoders know
  return const _Kind('image/jpeg', false, _unknownSize);
}
