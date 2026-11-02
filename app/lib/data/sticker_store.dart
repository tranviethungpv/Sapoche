import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_extra.dart';

/// Who made a pack and under which licence it may be used.
class StickerCredit {
  const StickerCredit({required this.name, required this.by, required this.license, required this.url});

  final String name;
  final String by;
  final String license;
  final String url;
}

/// A pack as the server's index lists it.
class StickerPackInfo {
  const StickerPackInfo({
    required this.id,
    required this.names,
    required this.icon,
    required this.count,
    required this.bytes,
    required this.credit,
  });

  final String id;

  /// The name by language code (`en`, `vi`).
  final Map<String, String> names;

  /// The id of the sticker that stands for the pack.
  final String icon;
  final int count;

  /// What the whole pack weighs.
  final int bytes;
  final StickerCredit? credit;

  /// The name in [language], or in English, or the id.
  String name(String language) => names[language] ?? names['en'] ?? id;

  static StickerPackInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || !StickerStore.isSafeId(id)) return null;
    final names = json['name'];
    final credit = json['credit'];
    final icon = json['icon'];
    return StickerPackInfo(
      id: id,
      names: names is Map
          ? {
              for (final e in names.entries)
                if (e.value is String) '${e.key}': e.value as String,
            }
          : {},
      icon: icon is String && StickerStore.isSafeId(icon) ? icon : '',
      count: (json['count'] as num?)?.toInt() ?? 0,
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      credit: credit is Map
          ? StickerCredit(
              name: '${credit['name'] ?? ''}',
              by: '${credit['by'] ?? ''}',
              license: '${credit['license'] ?? ''}',
              url: '${credit['url'] ?? ''}',
            )
          : null,
    );
  }
}

/// One sticker of a pack.
class Sticker {
  const Sticker({required this.id, required this.emoji, this.keywords = const [], this.group = ''});

  final String id;

  /// The emoji it stands for, which is what apps that do not have the pack show.
  final String emoji;
  final List<String> keywords;
  final String group;

  /// Whether a search for [query] (already lower case and trimmed) finds it: by a part of a keyword, or by its emoji.
  bool matches(String query) =>
      query.isEmpty || emoji.contains(query) || keywords.any((word) => word.toLowerCase().contains(query));
}

/// A pack with its stickers.
class StickerPack {
  const StickerPack({required this.id, required this.stickers});

  final String id;
  final List<Sticker> stickers;

  Sticker? sticker(String id) {
    for (final s in stickers) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// Where the files of the packs are kept on this device: a folder per pack. Names are checked by the one that
/// implements it, for what is read from a message is not to be trusted with a path.
abstract class StickerDisk {
  /// The file [name] of [pack], or null when there is none.
  Future<Uint8List?> read(String pack, String name);

  Future<void> write(String pack, String name, Uint8List bytes);

  /// Everything of [pack].
  Future<void> deletePack(String pack);
}

/// [StickerDisk] in a folder of the app's cache.
class FolderStickerDisk implements StickerDisk {
  FolderStickerDisk(this.root);

  final Directory root;

  static final _name = RegExp(r'^[A-Za-z0-9_-]{1,64}(\.[a-z]{1,8})?$');

  File? _file(String pack, String name) {
    if (!StickerStore.isSafeId(pack) || !_name.hasMatch(name)) return null;
    return File('${root.path}${Platform.pathSeparator}$pack${Platform.pathSeparator}$name');
  }

  @override
  Future<Uint8List?> read(String pack, String name) async {
    try {
      final file = _file(pack, name);
      return file != null && await file.exists() ? await file.readAsBytes() : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String pack, String name, Uint8List bytes) async {
    try {
      final file = _file(pack, name);
      if (file == null) return;
      await file.parent.create(recursive: true);
      // Written aside and moved, so a file half written is never read
      final part = File('${file.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(file.path);
    } on Object {
      // Not kept then: it is fetched again when it is wanted
    }
  }

  @override
  Future<void> deletePack(String pack) async {
    try {
      if (!StickerStore.isSafeId(pack)) return;
      final folder = Directory('${root.path}${Platform.pathSeparator}$pack');
      if (await folder.exists()) await folder.delete(recursive: true);
    } on Object {
      // Left for the system to clear with the cache
    }
  }
}

/// How a pack stands on this device.
enum StickerPackState { notAdded, downloading, ready, notDownloaded }

/// The sticker packs of the app: which exist on the server, which this device has added, the stickers used lately, and
/// the pictures themselves. The packs are plain files on the room server (`/stickers/…`, no key). Where the device has a
/// folder to keep them in, adding a pack fetches all of it in the background; in a browser, which keeps what it fetched
/// by itself, adding only records the choice.
class StickerStore extends ChangeNotifier {
  StickerStore({
    required SharedPreferences prefs,
    required this._server,
    Future<StickerDisk?> Function()? disk,
    http.Client? client,
  }) : _prefs = prefs,
       _diskOf = disk,
       _client = client ?? http.Client(),
       _added = prefs.getStringList(_keyAdded)?.where(isSafeId).toList(),
       _recent = _readRecent(prefs);

  /// Opens the store with the preferences of the app. [cacheFolder] is where the packs go where there is such a folder.
  static Future<StickerStore> load({
    required String Function() server,
    Future<String?> Function()? cacheFolder,
    http.Client? client,
  }) async => StickerStore(
    prefs: await SharedPreferences.getInstance(),
    server: server,
    client: client,
    disk: kIsWeb || cacheFolder == null
        ? null
        : () async {
            try {
              final base = await cacheFolder();
              if (base == null) return null;
              return FolderStickerDisk(
                await Directory('$base${Platform.pathSeparator}stickers').create(recursive: true),
              );
            } on Object {
              return null;
            }
          },
  );

  static const _keyAdded = 'stickers.added';
  static const _keyRecent = 'stickers.recent';
  static const _keyIndex = 'stickers.index';

  /// How many packs a device that never chose has from the start.
  static const defaultPacks = 3;

  /// How many stickers the recent tab holds.
  static const maxRecent = 30;

  /// Files that are bigger are not pictures of a pack.
  static const _maxFileBytes = 2 * 1024 * 1024;

  /// Pictures kept in memory, the latest used last.
  static const _memoryCount = 48;

  /// Files fetched at the same time when a pack is downloaded.
  static const _parallel = 3;

  static const _timeout = Duration(seconds: 15);
  static final _safeId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// Whether [id] is fit to be a folder or file name: ids come from the server and from messages.
  static bool isSafeId(String id) => _safeId.hasMatch(id);

  final SharedPreferences _prefs;
  final String Function() _server;
  final Future<StickerDisk?> Function()? _diskOf;
  final http.Client _client;

  /// Ids of the packs this device added, in the order added; null while it never chose (and so has the defaults).
  List<String>? _added;
  List<StickerExtra> _recent;
  List<StickerPackInfo> _packs = const [];
  bool _indexFetched = false;
  Future<List<StickerPackInfo>>? _indexing;
  Future<void>? _ready;
  Future<StickerDisk?>? _disk;
  StickerDisk? _diskNow;

  final _loaded = <String, StickerPack>{};
  final _packing = <String, Future<StickerPack?>>{};
  final _memory = <String, Uint8List>{};
  final _inflight = <String, Future<Uint8List?>>{};

  /// Pictures the server said are not there: not asked for again until the app is closed.
  final _gone = <String>{};
  final _progress = <String, double>{};
  final _complete = <String>{};
  final _generation = <String, int>{};

  // ------------------------------------------------------------------ what is listed

  /// The packs the server lists (the last list it gave, or the one kept from before while it cannot be reached).
  List<StickerPackInfo> get packs => _packs;

  /// The server's list came this session.
  bool get indexFetched => _indexFetched;

  /// Ids of the packs this device has added.
  List<String> get added => List.unmodifiable(_added ?? const <String>[]);

  /// The added packs the list knows, in the order added.
  List<StickerPackInfo> get addedPacks => [
    for (final id in _added ?? const <String>[])
      for (final info in _packs)
        if (info.id == id) info,
  ];

  bool isAdded(String id) => _added?.contains(id) ?? false;

  /// The stickers used lately, the latest first.
  List<StickerExtra> get recent => List.unmodifiable(_recent);

  Uri? _uri(String path) {
    final base = _server().trim().replaceAll(RegExp(r'/+$'), '');
    if (!base.startsWith('http://') && !base.startsWith('https://')) return null;
    return Uri.tryParse('$base/stickers/$path');
  }

  Future<http.Response?> _get(String path) async {
    final uri = _uri(path);
    if (uri == null) return null;
    try {
      return await _client.get(uri).timeout(_timeout);
    } on Object {
      return null;
    }
  }

  /// The packs the server lists; empty when it has none or cannot be reached (the one kept from before stands in while
  /// that is so). Asked once a session unless [force].
  Future<List<StickerPackInfo>> loadIndex({bool force = false}) {
    if (_indexFetched && !force) return Future.value(_packs);
    return _indexing ??= _fetchIndex().whenComplete(() => _indexing = null);
  }

  Future<List<StickerPackInfo>> _fetchIndex() async {
    final reply = await _get('index.json');
    final text = reply == null || reply.statusCode != 200 ? null : utf8.decode(reply.bodyBytes, allowMalformed: true);
    var parsed = text == null ? null : parseIndex(text);
    _indexFetched = parsed != null;
    if (text != null && parsed != null) {
      _prefs.setString(_keyIndex, text).ignore();
    } else {
      final kept = _prefs.getString(_keyIndex);
      parsed = kept == null ? null : parseIndex(kept);
    }
    _packs = parsed ?? const [];
    notifyListeners();
    return _packs;
  }

  /// The packs in [body], or null when it is no index (a server without stickers answers with its web page).
  @visibleForTesting
  static List<StickerPackInfo>? parseIndex(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map || json['packs'] is! List) return null;
      return [for (final item in (json['packs'] as List).take(40)) ?StickerPackInfo.fromJson(item)];
    } on Object {
      return null;
    }
  }

  /// The stickers of [id], from memory, the disk or the server; null where none can be had.
  Future<StickerPack?> pack(String id) {
    if (!isSafeId(id)) return Future.value(null);
    final kept = _loaded[id];
    if (kept != null) return Future.value(kept);
    return _packing[id] ??= _fetchPack(id).whenComplete(() {
      _packing.remove(id); // not returned: it is this very future
    });
  }

  Future<StickerPack?> _fetchPack(String id) async {
    final disk = await _resolveDisk();
    final onDisk = await disk?.read(id, 'pack.json');
    var pack = onDisk == null ? null : _parsePack(id, utf8.decode(onDisk, allowMalformed: true));
    if (pack == null) {
      final reply = await _get('$id/pack.json');
      if (reply == null || reply.statusCode != 200) return null;
      pack = _parsePack(id, utf8.decode(reply.bodyBytes, allowMalformed: true));
      if (pack != null && disk != null) await disk.write(id, 'pack.json', reply.bodyBytes);
    }
    if (pack != null) {
      _loaded[id] = pack;
      notifyListeners();
    }
    return pack;
  }

  static StickerPack? _parsePack(String id, String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map || json['stickers'] is! List) return null;
      final stickers = <Sticker>[];
      for (final item in (json['stickers'] as List).take(1000)) {
        if (item is! Map) continue;
        final sid = item['id'];
        if (sid is! String || !isSafeId(sid)) continue;
        final words = item['k'];
        stickers.add(
          Sticker(
            id: sid,
            emoji: '${item['e'] ?? ''}',
            keywords: words is List ? [for (final w in words) '$w'] : const [],
            group: '${item['g'] ?? ''}',
          ),
        );
      }
      return StickerPack(id: id, stickers: stickers);
    } on Object {
      return null;
    }
  }

  /// The pack already loaded, if it is.
  StickerPack? loadedPack(String id) => _loaded[id];

  // ------------------------------------------------------------------ the first use, adding and removing

  /// Asks for the list and, the first time this device uses stickers, adds the first [defaultPacks] packs of it. A device
  /// that downloads then fetches what is not on it yet. Where the list cannot be had nothing is decided, and the next
  /// call tries again.
  Future<void> ensureReady() => _ready ??= _prepare().whenComplete(() {
    if (_packs.isEmpty) _ready = null;
  });

  Future<void> _prepare() async {
    await loadIndex();
    if (_packs.isEmpty) return;
    if (_added == null) {
      _added = [for (final info in _packs.take(defaultPacks)) info.id];
      _saveAdded();
    }
    final disk = await _resolveDisk();
    if (disk != null) {
      for (final id in _added!) {
        if (await disk.read(id, 'complete.mark') != null) _complete.add(id);
      }
    }
    notifyListeners();
    for (final id in _added!) {
      download(id).ignore();
    }
  }

  void _saveAdded() => _prefs.setStringList(_keyAdded, _added ?? const []).ignore();

  /// Adds the pack [id]; where the device keeps files, all of it is fetched in the background.
  Future<void> add(String id) async {
    if (!isSafeId(id) || isAdded(id)) return;
    _added = [...?_added, id];
    _saveAdded();
    notifyListeners();
    await download(id);
  }

  /// Takes the pack [id] off this device, with its files (and stops its download).
  Future<void> remove(String id) async {
    if (!isAdded(id)) return;
    _added = [...?_added]..remove(id);
    _saveAdded();
    _generation[id] = (_generation[id] ?? 0) + 1;
    _progress.remove(id);
    _complete.remove(id);
    notifyListeners();
    await (await _resolveDisk())?.deletePack(id);
  }

  /// Where the pack [id] stands.
  StickerPackState state(String id) {
    if (!isAdded(id)) return StickerPackState.notAdded;
    if (_progress.containsKey(id)) return StickerPackState.downloading;
    return needsDownload(id) ? StickerPackState.notDownloaded : StickerPackState.ready;
  }

  /// How far the download of [id] has come (0 to 1); null when none is going on.
  double? progressOf(String id) => _progress[id];

  /// The pack is added, this device keeps files, and not all of the pack is on it.
  bool needsDownload(String id) =>
      isAdded(id) && _diskNow != null && !_complete.contains(id) && !_progress.containsKey(id);

  Future<StickerDisk?> _resolveDisk() =>
      _disk ??= (_diskOf?.call() ?? Future<StickerDisk?>.value()).then((disk) => _diskNow = disk);

  /// Fetches all of the pack [id] into the folder of the app, unless it is all there or a download is going on. Does
  /// nothing where the device keeps no files. Completes when the download ended, one way or the other.
  Future<void> download(String id) async {
    if (!isSafeId(id) || _progress.containsKey(id) || _complete.contains(id)) return;
    final disk = await _resolveDisk();
    if (disk == null || !isAdded(id) || _progress.containsKey(id)) return;
    if (await disk.read(id, 'complete.mark') != null) {
      _complete.add(id);
      notifyListeners();
      return;
    }
    final generation = _generation[id] = (_generation[id] ?? 0) + 1;
    bool stale() => _generation[id] != generation;
    _progress[id] = 0;
    notifyListeners();
    var ok = false;
    try {
      final pack = await this.pack(id);
      if (pack != null && !stale()) {
        final todo = [for (final s in pack.stickers) s.id];
        var next = 0;
        var done = 0;
        var failed = false;
        Future<void> worker() async {
          while (!failed && !stale() && next < todo.length) {
            final sticker = todo[next++];
            final name = '$sticker.webp';
            if (await disk.read(id, name) == null) {
              final bytes = await _fetchImage(id, sticker);
              if (bytes == null) {
                failed = true;
                return;
              }
              if (stale()) return;
              await disk.write(id, name, bytes);
            }
            done++;
            final share = done / todo.length;
            if (!stale() && (share * 100).floor() != ((_progress[id] ?? 0) * 100).floor()) {
              _progress[id] = share;
              notifyListeners();
            }
          }
        }

        await Future.wait([for (var i = 0; i < min(_parallel, todo.length); i++) worker()]);
        ok = !failed && !stale();
        if (ok) await disk.write(id, 'complete.mark', Uint8List.fromList([1]));
      }
    } finally {
      if (!stale()) {
        _progress.remove(id);
        if (ok) _complete.add(id);
        notifyListeners();
      }
    }
  }

  // ------------------------------------------------------------------ recent

  static List<StickerExtra> _readRecent(SharedPreferences prefs) {
    final out = <StickerExtra>[];
    for (final line in prefs.getStringList(_keyRecent) ?? const <String>[]) {
      try {
        final extra = StickerExtra.fromJson(jsonDecode(line) as Map<String, dynamic>);
        if (isSafeId(extra.pack) && isSafeId(extra.sticker)) out.add(extra);
      } on Object {
        // A line from a version that wrote it otherwise
      }
    }
    return out.take(maxRecent).toList();
  }

  /// [sticker] was sent: it goes first in the recent ones, once.
  void use(StickerExtra sticker) {
    _recent = [
      sticker,
      for (final s in _recent)
        if (s.pack != sticker.pack || s.sticker != sticker.sticker) s,
    ].take(maxRecent).toList();
    _prefs.setStringList(_keyRecent, [for (final s in _recent) jsonEncode(s.toJson())]).ignore();
    notifyListeners();
  }

  // ------------------------------------------------------------------ pictures

  /// The picture of the sticker [id] of [pack]: from memory, from the disk, or else from the server (and then kept on the
  /// disk, that one file). Null when it cannot be had; callers asking for the same picture share one fetch.
  Future<Uint8List?> image(String pack, String id) {
    if (!isSafeId(pack) || !isSafeId(id)) return Future.value(null);
    final key = '$pack/$id';
    final kept = _memory.remove(key);
    if (kept != null) {
      _memory[key] = kept; // the latest used goes last
      return Future.value(kept);
    }
    if (_gone.contains(key)) return Future.value(null);
    return _inflight[key] ??= _loadImage(pack, id, key).whenComplete(() {
      _inflight.remove(key);
    });
  }

  Future<Uint8List?> _loadImage(String pack, String id, String key) async {
    final disk = await _resolveDisk();
    var bytes = await disk?.read(pack, '$id.webp');
    if (bytes == null) {
      bytes = await _fetchImage(pack, id);
      if (bytes != null && disk != null) await disk.write(pack, '$id.webp', bytes);
    }
    if (bytes != null) {
      _memory[key] = bytes;
      while (_memory.length > _memoryCount) {
        _memory.remove(_memory.keys.first);
      }
    }
    return bytes;
  }

  /// The file from the server, or null: unreachable, or no picture (a server without the pack answers with its web page).
  Future<Uint8List?> _fetchImage(String pack, String id) async {
    final reply = await _get('$pack/$id.webp');
    if (reply == null) return null;
    if (reply.statusCode >= 500) return null; // the server is ailing, not the file missing
    final bytes = reply.bodyBytes;
    if (reply.statusCode != 200 || !_looksLikeImage(bytes)) {
      _gone.add('$pack/$id');
      return null;
    }
    return bytes;
  }

  static bool _looksLikeImage(Uint8List b) {
    if (b.length < 12 || b.length > _maxFileBytes) return false;
    final webp = b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45;
    final png = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
    final gif = b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38;
    return webp || png || gif;
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
