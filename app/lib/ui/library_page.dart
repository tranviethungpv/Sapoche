import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library_controller.dart';
import '../format.dart';
import '../data/models.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'collection_screen.dart';
import 'home_shell.dart';
import 'scope.dart';
import 'settings_page.dart';
import 'widgets/delete_background.dart';
import 'widgets/download_actions.dart';
import 'widgets/page_width.dart';
import 'widgets/play_row.dart';
import 'widgets/player_backdrop.dart';
import 'widgets/playlist_cover.dart';
import 'widgets/scroll_edge.dart';
import 'widgets/text_dialog.dart';
import 'widgets/track_menu.dart';
import 'widgets/track_tile.dart';

/// What a person keeps: liked songs, what they heard lately, and their playlists. Opening one puts its page
/// over the tab, as the page of an album is, with a way back.
/// What the sidebar of a wide screen asks the library to open: [liked], [downloaded], [local] or the id of a playlist (never
/// negative). Set to a value to ask, and the page forgets it once it has been shown.
class LibraryRequests extends ValueNotifier<int?> {
  LibraryRequests() : super(null);

  static const liked = -1;
  static const downloaded = -2;
  static const local = -3;
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.requests});

  final LibraryRequests? requests;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

sealed class _Open {
  const _Open();
}

class _Liked extends _Open {
  const _Liked();
}

class _Recent extends _Open {
  const _Recent();
}

class _Downloaded extends _Open {
  const _Downloaded();
}

class _Local extends _Open {
  const _Local();
}

class _Playlist extends _Open {
  const _Playlist(this.id);
  final int id;
}

class _LibraryPageState extends State<LibraryPage> {
  @override
  void initState() {
    super.initState();
    widget.requests?.addListener(_onRequest);
  }

  @override
  void didUpdateWidget(LibraryPage old) {
    super.didUpdateWidget(old);
    if (old.requests != widget.requests) {
      old.requests?.removeListener(_onRequest);
      widget.requests?.addListener(_onRequest);
    }
  }

  @override
  void dispose() {
    widget.requests?.removeListener(_onRequest);
    super.dispose();
  }

  void _onRequest() {
    final request = widget.requests?.value;
    if (request == null) return;
    widget.requests!.value = null;
    _show(switch (request) {
      LibraryRequests.liked => const _Liked(),
      LibraryRequests.downloaded => const _Downloaded(),
      LibraryRequests.local => const _Local(),
      final id => _Playlist(id),
    });
  }

  void _show(_Open value) {
    if (!mounted) return;
    _openScreen(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    // The list starts below the status bar and scrolls up under it, to its glass edge
    return SafeArea(
      top: false,
      bottom: false,
      child: ListenableBuilder(
        listenable: library,
        builder: (context, _) => _Overview(library: library, onOpen: _show),
      ),
    );
  }
}

void _openScreen(BuildContext context, _Open value) {
  if (value is _Playlist) AppScope.of(context).library.openPlaylist(value.id);
  // A message still showing would be drawn by the new page too, and the two would fight over it
  ScaffoldMessenger.of(context).removeCurrentSnackBar();
  TabNavigation.push(
    context,
    MaterialPageRoute<void>(builder: (_) => _LibraryScreen(open: value)),
  );
}

/// Opens one list of the library over the tab that is showing, from outside the library: the liked songs
/// ([LibraryRequests.liked]), the downloads ([LibraryRequests.downloaded]) or the playlist with that id.
void openLibrarySpot(BuildContext context, int spot) =>
    _openScreen(context, switch (spot) {
      LibraryRequests.liked => const _Liked(),
      LibraryRequests.downloaded => const _Downloaded(),
      LibraryRequests.local => const _Local(),
      final id => _Playlist(id),
    });

/// The page of one list of the library.
class _LibraryScreen extends StatelessWidget {
  const _LibraryScreen({required this.open});

  final _Open open;

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => switch (open) {
        _Liked() => _TrackList(
          title: S.likedSongs,
          tracks: library.liked,
          cover: (side) => _IconTile(
            Icons.favorite_rounded,
            size: side,
            radius: 16,
            iconSize: side * 0.4,
          ),
          menu: [
            if (library.liked.isNotEmpty)
              _MenuAction(
                S.downloadAll,
                () => startDownload(context, library.liked),
              ),
          ],
        ),
        _Downloaded() => _TrackList(
          title: S.downloadedSongs,
          tracks: [for (final d in library.downloads) d.track],
          subtitles: [
            for (final d in library.downloads)
              '${d.track.artist} · ${switch (d.state) {
                DownloadState.done => formatBytes(d.bytes),
                DownloadState.queued => S.queuedToDownload,
                DownloadState.waiting => S.waitingToDownload,
                DownloadState.failed => S.downloadFailed,
              }}',
          ],
          cover: (side) => _IconTile(
            Icons.download_done_rounded,
            size: side,
            radius: 16,
            iconSize: side * 0.4,
          ),
          emptyTitle: S.noDownloadsTitle,
          emptyBody: S.noDownloadsBody,
          menu: [
            if (library.downloads.isNotEmpty)
              _MenuAction(
                S.deleteAll,
                () => _confirmDeleteDownloads(context, library),
              ),
          ],
        ),
        _Recent() => _TrackList(
          title: S.recentlyPlayed,
          tracks: [for (final e in library.recent) e.track],
          subtitles: [
            for (final e in library.recent)
              '${e.track.artist} · ${S.ago(DateTime.now().difference(e.at))}',
          ],
          cover: (side) => _IconTile(
            Icons.history_rounded,
            size: side,
            radius: 16,
            iconSize: side * 0.4,
          ),
          menu: [
            if (library.recent.isNotEmpty)
              _MenuAction(
                S.clearHistory,
                () => _confirmClear(context, library),
              ),
          ],
        ),
        _Local() => const _LocalPage(),
        _Playlist(:final id) => _PlaylistPage(library: library, id: id),
      },
    );
  }

  Future<void> _confirmDeleteDownloads(
    BuildContext context,
    LibraryController library,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(S.deleteDownloadsQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.delete),
          ),
        ],
      ),
    );
    if (ok == true) library.clearDownloads();
  }

  Future<void> _confirmClear(
    BuildContext context,
    LibraryController library,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(S.clearHistoryQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.clear),
          ),
        ],
      ),
    );
    if (ok == true) library.clearHistory();
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.library, required this.onOpen});

  final LibraryController library;
  final ValueChanged<_Open> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final p = context.palette;
    return ScrollEdge(
      title: S.tabLibrary,
      child: ListView(
        padding: EdgeInsets.only(
          top: ScrollEdge.topOf(context),
          bottom: HomeShell.bottomInsetOf(context),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
            child: Row(
              children: [
                Expanded(child: Text(S.tabLibrary, style: theme.headlineLarge)),
                IconButton(
                  onPressed: () => openSettings(context),
                  tooltip: S.settingsTitle,
                  style: roundButtonStyle(context, size: 40),
                  icon: Icon(Icons.settings_outlined, size: 22, color: p.text),
                ),
              ],
            ),
          ),
          _CollectionRow(
            leading: const _IconTile(Icons.favorite_rounded),
            title: S.likedSongs,
            subtitle: S.songCount(library.liked.length),
            onTap: () => onOpen(const _Liked()),
          ),
          _CollectionRow(
            leading: const _IconTile(Icons.history_rounded),
            title: S.recentlyPlayed,
            subtitle: S.songCount(library.recent.length),
            onTap: () => onOpen(const _Recent()),
          ),
          _CollectionRow(
            leading: const _IconTile(Icons.download_done_rounded),
            title: S.downloadedSongs,
            subtitle: S.songCount(
              library.downloads
                  .where((d) => d.state == DownloadState.done)
                  .length,
            ),
            onTap: () => onOpen(const _Downloaded()),
          ),
          if (library.localStatus.enabled)
            _CollectionRow(
              leading: const _IconTile(Icons.smartphone_rounded),
              title: S.localMusic,
              subtitle: library.localStatus.access == LocalAccess.granted
                  ? S.songCount(library.localStatus.count)
                  : S.localAllowTitle,
              onTap: () => onOpen(const _Local()),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 16, 4),
            child: Row(
              children: [
                Expanded(child: Text(S.playlists, style: theme.titleLarge)),
                PopupMenuButton<String>(
                  useRootNavigator: true,
                  style: roundButtonStyle(context, size: 40),
                  icon: Icon(Icons.add_rounded, color: p.text),
                  tooltip: S.newPlaylist,
                  color: p.brightness == Brightness.light
                      ? const Color(0xFFFFF7F9)
                      : const Color(0xFF2B1F25),
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  onSelected: (value) => value == 'new'
                      ? _create(context, library)
                      : _import(context, library),
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'new', child: Text(S.newPlaylist)),
                    PopupMenuItem(
                      value: 'import',
                      child: Text(S.importFromLink),
                    ),
                  ],
                ),
              ],
            ),
          ),
          for (final playlist in library.playlists)
            _CollectionRow(
              leading: PlaylistCover(thumbs: playlist.thumbs, size: 54),
              title: playlist.name,
              subtitle: S.songCount(playlist.count),
              onTap: () => onOpen(_Playlist(playlist.id)),
            ),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context, LibraryController library) async {
    final name = await showTextDialog(
      context,
      title: S.newPlaylist,
      hint: S.playlistName,
      maxLength: 60,
    );
    if (name == null || name.isEmpty) return;
    final id = await library.createPlaylist(name);
    if (id != null) onOpen(_Playlist(id));
  }

  /// Makes a playlist out of a YouTube link: the songs of a playlist, or the one song of a video.
  Future<void> _import(BuildContext context, LibraryController library) async {
    final room = AppScope.roomOf(context);
    final messenger = ScaffoldMessenger.of(context);
    final text = await showTextDialog(
      context,
      title: S.importFromLink,
      hint: S.importHint,
      maxLength: 300,
      capitalization: TextCapitalization.none,
    );
    if (text == null || text.isEmpty) return;
    void say(String message) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    final LinkResult? link;
    try {
      link = await room.lookup(text);
    } on Object {
      return say(S.importFailed);
    }
    if (link == null) return say(S.importFailed);
    if (link.tracks.isEmpty) return say(S.importEmpty);
    final id = await library.createPlaylist(
      link.playlistTitle ?? link.tracks.first.title,
      link.tracks,
    );
    if (id != null) onOpen(_Playlist(id));
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile(
    this.icon, {
    this.size = 54,
    this.radius = SapocheTheme.artworkRadius,
    this.iconSize = 24,
  });

  final IconData icon;
  final double size;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: p.primaryContainer,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(icon, size: iconSize, color: p.primary),
    );
  }
}

class _CollectionRow extends StatelessWidget {
  const _CollectionRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: p.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// A playlist: its songs can be dragged into another order and swiped away, and it can be renamed or deleted.
class _PlaylistPage extends StatelessWidget {
  const _PlaylistPage({required this.library, required this.id});

  final LibraryController library;
  final int id;

  @override
  Widget build(BuildContext context) {
    final playlist = library.playlists.where((p) => p.id == id).firstOrNull;
    final tracks = library.playlistTracks(id);
    return _TrackList(
      title: playlist?.name ?? '',
      tracks: tracks,
      cover: (side) => PlaylistCover(
        thumbs: playlist?.thumbs ?? const [],
        size: side,
        radius: 16,
        sharp: true,
      ),
      emptyTitle: S.emptyPlaylistTitle,
      emptyBody: S.emptyPlaylistBody,
      onRemove: (track) => library.removeFromPlaylist(id, track),
      onMove: (track, to) => library.movePlaylistItem(id, track, to),
      menu: [
        if (tracks.isNotEmpty)
          _MenuAction(S.downloadAll, () => startDownload(context, tracks)),
        _MenuAction(S.rename, () => _rename(context, playlist)),
        _MenuAction(S.deletePlaylist, () => _delete(context, playlist)),
      ],
    );
  }

  Future<void> _rename(BuildContext context, SavedPlaylist? playlist) async {
    final name = await showTextDialog(
      context,
      title: S.rename,
      hint: S.playlistName,
      initial: playlist?.name ?? '',
      maxLength: 60,
    );
    if (name != null && name.isNotEmpty) library.renamePlaylist(id, name);
  }

  Future<void> _delete(BuildContext context, SavedPlaylist? playlist) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(S.deletePlaylistQuestion(playlist?.name ?? '')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.delete),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    // The page leaves first and the playlist goes once it has, so that the page is not seen empty on its way out
    final route = ModalRoute.of(context)! as TransitionRoute<void>;
    Navigator.pop(context);
    await route.completed;
    library.deletePlaylist(id);
  }
}

enum _LocalSort { recent, title, artist, album }

/// The music files on this phone, laid out as the other lists are, with a box to search them and a way to order them.
class _LocalPage extends StatefulWidget {
  const _LocalPage();

  @override
  State<_LocalPage> createState() => _LocalPageState();
}

class _LocalPageState extends State<_LocalPage> with WidgetsBindingObserver {
  final _query = TextEditingController();
  _LocalSort _sort = _LocalSort.recent;
  LibraryController? _library;

  bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_library != null) return;
    final library = _library = AppScope.of(context).library;
    // The list is read while this page is open, and read again from the files: they may have changed since
    library.watchLocal(true).then((_) => library.scanLocal());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Music copied in, or the permission given in the settings of the phone, while the app was away
    if (state == AppLifecycleState.resumed) {
      _library?.watchLocal(true).then((_) => _library?.scanLocal());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _library?.watchLocal(false);
    _query.dispose();
    super.dispose();
  }

  List<LocalSong> _shown(List<LocalSong> all) {
    final q = _query.text.trim().toLowerCase();
    final list = [
      for (final s in all)
        if (!s.missing &&
            (q.isEmpty ||
                s.track.title.toLowerCase().contains(q) ||
                s.track.artist.toLowerCase().contains(q) ||
                s.album.toLowerCase().contains(q)))
          s,
    ];
    int by(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    list.sort(
      (a, b) => switch (_sort) {
        _LocalSort.recent => b.addedAt.compareTo(a.addedAt),
        _LocalSort.title => by(a.track.title, b.track.title),
        _LocalSort.artist => by(a.track.artist, b.track.artist),
        _LocalSort.album => by(a.album, b.album),
      },
    );
    return list;
  }

  String _sortName(_LocalSort sort) => switch (sort) {
    _LocalSort.recent => S.sortRecent,
    _LocalSort.title => S.sortTitle,
    _LocalSort.artist => S.sortArtist,
    _LocalSort.album => S.sortAlbum,
  };

  Future<void> _addFiles(LibraryController library) async {
    final copied = await library.importLocal();
    if (copied == null || copied == 0 || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(S.localAdded(copied))));
  }

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    return ListenableBuilder(
      // The files have a notifier of their own, apart from the library's (see [LibraryController.localSongs])
      listenable: Listenable.merge([library, library.localSongs]),
      builder: (context, _) {
        final status = library.localStatus;
        // An iPhone needs no permission: its music is in the folder of the app
        final granted = _ios || status.access == LocalAccess.granted;
        final shown = granted ? _shown(library.local) : const <LocalSong>[];
        final searching = _query.text.trim().isNotEmpty;
        return _TrackList(
          title: S.localMusic,
          tracks: [for (final s in shown) s.track],
          subtitles: [
            for (final s in shown)
              [s.track.artist, s.album].where((t) => t.isNotEmpty).join(' · '),
          ],
          cover: (side) => _IconTile(
            Icons.smartphone_rounded,
            size: side,
            radius: 16,
            iconSize: side * 0.4,
          ),
          menu: [
            if (granted) ...[
              for (final sort in _LocalSort.values)
                _MenuAction(
                  '${S.sortBy}: ${_sortName(sort)}',
                  () => setState(() => _sort = sort),
                ),
              _MenuAction(S.localRefresh, library.scanLocal),
              if (_ios) _MenuAction(S.localAddFiles, () => _addFiles(library)),
            ],
          ],
          filterBar: granted && library.local.any((s) => !s.missing)
              ? _LocalFilter(
                  controller: _query,
                  unsupported: library.lastScan.unsupported,
                  onChanged: () => setState(() {}),
                )
              : null,
          emptyView: granted
              ? _LocalEmpty(
                  title: S.localEmptyTitle,
                  body: searching
                      ? null
                      : _ios
                      ? S.localEmptyIos
                      : S.localEmptyAndroid,
                  action: _ios && !searching ? S.localAddFiles : null,
                  onAction: () => _addFiles(library),
                )
              : _LocalEmpty(
                  title: S.localAllowTitle,
                  body: status.access == LocalAccess.blocked
                      ? S.localBlockedBody
                      : S.localAllowBody,
                  action: status.access == LocalAccess.blocked
                      ? S.localOpenSettings
                      : S.localAllow,
                  onAction: library.requestLocalAccess,
                ),
        );
      },
    );
  }
}

/// The box that narrows the songs on this phone, and a word about the files that cannot be played here.
class _LocalFilter extends StatelessWidget {
  const _LocalFilter({
    required this.controller,
    required this.unsupported,
    required this.onChanged,
  });

  final TextEditingController controller;
  final int unsupported;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
      child: Column(
        children: [
          TextField(
            controller: controller,
            onChanged: (_) => onChanged(),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: S.localFilter,
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
            ),
          ),
          if (unsupported > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                S.localUnsupported(unsupported),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: p.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

/// What the list of the music on this phone says when there is nothing to list, with the one thing to do about it.
class _LocalEmpty extends StatelessWidget {
  const _LocalEmpty({
    required this.title,
    this.body,
    this.action,
    this.onAction,
  });

  final String title;
  final String? body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 40, 36, 0),
      child: Column(
        children: [
          Icon(
            Icons.smartphone_rounded,
            size: 44,
            color: p.primary.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 14),
          Text(title, style: theme.titleMedium, textAlign: TextAlign.center),
          if (body != null) ...[
            const SizedBox(height: 6),
            Text(
              body!,
              textAlign: TextAlign.center,
              style: theme.bodyMedium?.copyWith(color: p.textSecondary),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 18),
            FilledButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      ),
    );
  }
}

/// One thing the "…" button of a list offers.
class _MenuAction {
  const _MenuAction(this.label, this.run);

  final String label;
  final VoidCallback run;
}

/// The songs of one collection, laid out as the page of an album is: the cover, what the collection is called, play
/// and shuffle, then the songs. With [onMove] the rows can be dragged into another order, with [onRemove] they can be
/// swiped away.
class _TrackList extends StatelessWidget {
  const _TrackList({
    required this.title,
    required this.tracks,
    required this.cover,
    this.subtitles,
    this.menu = const [],
    this.emptyTitle,
    this.emptyBody,
    this.emptyView,
    this.filterBar,
    this.onRemove,
    this.onMove,
  });

  final String title;
  final List<Track> tracks;

  /// Draws the cover at the side the page gives it.
  final Widget Function(double side) cover;

  /// Replaces the artist line of each row, when given.
  final List<String>? subtitles;

  /// What the "…" button beside Play offers; no button when there is nothing.
  final List<_MenuAction> menu;
  final String? emptyTitle;
  final String? emptyBody;

  /// Shown in place of [emptyTitle] and [emptyBody] when there are no songs.
  final Widget? emptyView;

  /// Drawn between the play buttons and the songs, e.g. a box to search the songs in.
  final Widget? filterBar;
  final ValueChanged<Track>? onRemove;
  final void Function(Track track, int toIndex)? onMove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final room = AppScope.roomOf(context);

    void confirm(String text) {
      HapticFeedback.selectionClick();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    }

    Future<void> add(Track track, {bool playNext = false}) async {
      if (room.snapshot.isQueued(track)) {
        confirm(S.alreadyInQueue);
        return;
      }
      // The others in a room do not have the file
      if (room.snapshot.inRoom && track.isLocal) {
        confirm(S.localNoRoom);
        return;
      }
      await room.add(track, playNext: playNext);
      if (context.mounted) {
        confirm(playNext ? S.willPlayNext : S.addedToQueue);
      }
    }

    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final inRoom = room.snapshot.inRoom;

        Future<void> playAll({required bool shuffle}) async {
          HapticFeedback.selectionClick();
          await room.playTracks(shuffle ? ([...tracks]..shuffle()) : tracks);
          // In a room the songs are only put on the queue: say so
          if (inRoom) confirm(S.playlistAdded);
        }

        final library = AppScope.of(context).library;
        Widget row(int i) {
          final track = tracks[i];
          // A song whose file is gone is dimmed and says so; there is nothing to play
          final missing = library.isMissing(track);
          final tile = TrackTile(
            track: track,
            subtitle: missing ? S.fileMissing : subtitles?[i],
            dimmed: missing,
            // Outside a room the song plays with the rest of the list behind it; in a room it is queued
            onTap: missing
                ? () => confirm(S.fileMissing)
                : inRoom
                ? () => add(track)
                : () => room.playTracks(tracks.sublist(i)),
            trailing: TrackMenu(
              track: track,
              onAdd: () => add(track),
              onPlayNext: () => add(track, playNext: true),
            ),
          );
          if (onRemove == null) return tile;
          return Dismissible(
            key: ValueKey('remove ${track.videoId}'),
            direction: DismissDirection.endToStart,
            background: const DeleteBackground(),
            onDismissed: (_) {
              HapticFeedback.lightImpact();
              onRemove!(track);
            },
            child: tile,
          );
        }

        // The page takes its colours from the first cover, as the page of an album does
        return Stack(
          fit: StackFit.expand,
          children: [
            PlayerBackdrop(coverUrl: tracks.firstOrNull?.thumb),
            Padding(
              padding: EdgeInsets.only(left: SideInset.of(context)),
              child: Scaffold(
                appBar: AppBar(leading: const RoundBackButton()),
                body: LayoutBuilder(
                  builder: (context, box) {
                    // Wide, the cover goes beside what is said of it, and the songs keep to a readable width
                    final wide = box.maxWidth >= 720;
                    final gutter = ((box.maxWidth - 1100) / 2).clamp(
                      0.0,
                      double.infinity,
                    );
                    final info = Column(
                      crossAxisAlignment: wide
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: wide
                              ? EdgeInsets.zero
                              : const EdgeInsets.fromLTRB(24, 18, 24, 0),
                          child: Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: wide
                                ? TextAlign.start
                                : TextAlign.center,
                            style: wide
                                ? theme.headlineLarge
                                : theme.headlineSmall,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            S.songCount(tracks.length),
                            style: theme.bodySmall?.copyWith(
                              color: p.textSecondary,
                            ),
                          ),
                        ),
                        if (tracks.isNotEmpty)
                          PlayRow(
                            inline: wide,
                            onPlay: () => playAll(shuffle: false),
                            onShuffle: () => playAll(shuffle: true),
                            more: menu.isEmpty ? null : _moreButton(context),
                          ),
                      ],
                    );
                    // A list with nothing in it that has its own words to say (not what the songs are for, but what is to
                    // be done about it) is only the title and those words, at the top: the cover and the count would
                    // push the one thing to do under the bars, and a page this short never scrolls to fold them
                    // (Not while a box to search them is above: a search that finds nothing keeps the page as it was)
                    final bare =
                        tracks.isEmpty && emptyView != null && filterBar == null;
                    return CustomScrollView(
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      slivers: [
                        SliverPadding(
                          padding: EdgeInsets.symmetric(horizontal: gutter),
                          sliver: SliverMainAxisGroup(
                            slivers: [
                              SliverToBoxAdapter(
                                child: bare
                                    ? Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          24,
                                          4,
                                          24,
                                          0,
                                        ),
                                        child: Text(
                                          title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                          style: theme.headlineSmall,
                                        ),
                                      )
                                    : wide
                                    ? Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          20,
                                          4,
                                          20,
                                          6,
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            CollectionCover(
                                              side: 232,
                                              picture: cover,
                                            ),
                                            const SizedBox(width: 32),
                                            Expanded(child: info),
                                          ],
                                        ),
                                      )
                                    : Column(
                                        children: [
                                          Center(
                                            child: CollectionCover(
                                              picture: cover,
                                            ),
                                          ),
                                          info,
                                          const SizedBox(height: 6),
                                        ],
                                      ),
                              ),
                              if (filterBar != null)
                                SliverToBoxAdapter(child: filterBar),
                              if (tracks.isEmpty &&
                                  (emptyTitle != null || emptyView != null))
                                SliverToBoxAdapter(
                                  child: emptyView ?? _empty(context),
                                )
                              else if (onMove != null)
                                SliverReorderableList(
                                  itemCount: tracks.length,
                                  onReorderItem: (from, to) =>
                                      onMove!(tracks[from], to),
                                  proxyDecorator: (child, _, animation) =>
                                      Material(
                                        color: Colors.transparent,
                                        elevation: 0,
                                        child: ScaleTransition(
                                          scale: Tween(
                                            begin: 1.0,
                                            end: 1.02,
                                          ).animate(animation),
                                          child: child,
                                        ),
                                      ),
                                  itemBuilder: (context, i) =>
                                      ReorderableDelayedDragStartListener(
                                        key: ValueKey(
                                          'row ${tracks[i].videoId}',
                                        ),
                                        index: i,
                                        child: row(i),
                                      ),
                                )
                              else
                                SliverList.builder(
                                  itemCount: tracks.length,
                                  itemBuilder: (context, i) => row(i),
                                ),
                              SliverToBoxAdapter(
                                child: SizedBox(
                                  // With the mini player open, and not as the bars are once a long page has folded
                                  // them: this one has nothing to scroll
                                  height: bare
                                      ? HomeShell.openBottomInsetOf(context)
                                      : HomeShell.bottomInsetOf(context) + 8,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The round "…" beside Play, with what the list offers.
  Widget _moreButton(BuildContext context) {
    final p = context.palette;
    return PopupMenuButton<VoidCallback>(
      tooltip: S.showMore,
      icon: const Icon(Icons.more_horiz_rounded),
      style: roundButtonStyle(context),
      color: p.brightness == Brightness.light
          ? const Color(0xFFFFF7F9)
          : const Color(0xFF2B1F25),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (run) => run(),
      itemBuilder: (context) => [
        for (final action in menu)
          PopupMenuItem(value: action.run, child: Text(action.label)),
      ],
    );
  }

  Widget _empty(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 48, 36, 0),
      child: Column(
        children: [
          Icon(
            Icons.queue_music_rounded,
            size: 44,
            color: p.primary.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 14),
          Text(emptyTitle!, style: theme.titleMedium),
          if (emptyBody != null) ...[
            const SizedBox(height: 6),
            Text(
              emptyBody!,
              textAlign: TextAlign.center,
              style: theme.bodyMedium?.copyWith(color: p.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}
