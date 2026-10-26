import '../music_models.dart';

// Reads the answers of YouTube Music. Mirrors MusicParser.kt and MusicParser.swift, and is held to the same fixtures
// (native/core/src/test/resources/music). The shape of an answer is not promised to anybody, so every read goes through
// [_at] and gives null or nothing for what is missing, and whatever is left after that is still shown.

/// What plays after a song, and where its lyrics and its related page are asked for, when it has them.
class WatchNext {
  const WatchNext(this.tracks, {this.lyricsId, this.relatedId});
  final List<MusicTrack> tracks;
  final String? lyricsId;
  final String? relatedId;
}

class Related {
  const Related(this.more, this.otherPerformances, this.artists, this.playlists, this.about);
  final List<MusicTrack> more;
  final List<MusicTrack> otherPerformances;
  final List<ArtistCard> artists;
  final List<Release> playlists;
  final String? about;
}

abstract final class MusicParser {
  static WatchNext watchNext(Object? root) {
    final tabs = _elements(
      _at(root, ['contents', 'singleColumnMusicWatchNextResultsRenderer', 'tabbedRenderer', 'watchNextTabbedResultsRenderer', 'tabs']),
    ).map((t) => _at(t, ['tabRenderer'])).toList();
    final queue = [
      for (final item in _elements(_at(tabs.firstOrNull, ['content', 'musicQueueRenderer', 'content', 'playlistPanelRenderer', 'contents'])))
        ?_panelTrack(item),
    ];
    // A tab is only there to open when it has a page to go to
    String? pageOf(String title) {
      for (final t in tabs) {
        if (_string(_at(t, ['title'])) == title) return _string(_at(t, ['endpoint', 'browseEndpoint', 'browseId']));
      }
      return null;
    }

    return WatchNext(queue, lyricsId: pageOf('Lyrics'), relatedId: pageOf('Related'));
  }

  static Related related(Object? root) {
    var more = <MusicTrack>[];
    var other = <MusicTrack>[];
    final artists = <ArtistCard>[];
    final playlists = <Release>[];
    for (final shelf in _findAll(root, 'musicCarouselShelfRenderer')) {
      final title = _text(_at(shelf, ['header', 'musicCarouselShelfBasicHeaderRenderer', 'title']));
      final items = _elements(_at(shelf, ['contents']));
      final tracks = [for (final i in items) ?_listTrack(_at(i, ['musicResponsiveListItemRenderer']))];
      if (tracks.isNotEmpty && title == 'Other performances') {
        other = tracks;
      } else if (tracks.isNotEmpty && more.isEmpty) {
        more = tracks;
      } else {
        for (final item in items) {
          final card = _at(item, ['musicTwoRowItemRenderer']);
          final artist = _artistCard(card);
          if (artist != null) {
            artists.add(artist);
          } else {
            final list = _playlistCard(card);
            if (list != null) playlists.add(list);
          }
        }
      }
    }
    final about = _text(_at(_findAll(root, 'musicDescriptionShelfRenderer').firstOrNull, ['description']));
    return Related(more, other, artists, playlists, about);
  }

  static String? lyrics(Object? root) {
    final text = _text(_at(_findAll(root, 'musicDescriptionShelfRenderer').firstOrNull, ['description']));
    return text == null || text.trim().isEmpty ? null : text;
  }

  static ArtistPage artist(String id, Object? root) {
    final head = _at(root, ['header']);
    final header = _at(head, ['musicImmersiveHeaderRenderer']) ?? _at(head, ['musicVisualHeaderRenderer']);
    final topShelf = _findAll(root, 'musicShelfRenderer').firstOrNull;
    final topSongs = [
      for (final i in _elements(_at(topShelf, ['contents']))) ?_listTrack(_at(i, ['musicResponsiveListItemRenderer'])),
    ];
    var topSongsId = _string(
      _at(topShelf, ['title', 'runs', '0', 'navigationEndpoint', 'browseEndpoint', 'browseId']) ??
          _at(topShelf, ['bottomEndpoint', 'browseEndpoint', 'browseId']),
    );
    if (topSongsId != null && topSongsId.startsWith('VL')) topSongsId = topSongsId.substring(2);
    final albums = <Release>[];
    final singles = <Release>[];
    final similar = <ArtistCard>[];
    final others = <MusicShelf>[];
    for (final shelf in _findAll(root, 'musicCarouselShelfRenderer')) {
      final built = _carousel(shelf);
      if (built == null) continue;
      if (built.title == 'Albums') {
        albums.addAll(built.albums);
      } else if (built.title == 'Singles & EPs') {
        singles.addAll(built.albums);
      } else if (built.artists.isNotEmpty && built.tracks.isEmpty && built.albums.isEmpty && built.playlists.isEmpty) {
        similar.addAll(built.artists);
      } else {
        others.add(built);
      }
    }
    return ArtistPage(
      id: id,
      name: _text(_at(header, ['title'])) ?? '',
      description: _text(_at(header, ['description'])),
      subscribers: _text(_at(header, ['subscriptionButton', 'subscribeButtonRenderer', 'subscriberCountText'])),
      thumb: _thumbnail(_at(header, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
      topSongs: topSongs,
      albums: albums,
      singles: singles,
      similar: similar,
      shelves: others,
      topSongsId: topSongsId,
    );
  }

  /// An album or a playlist page: the header, the first songs and the rows below them.
  static CollectionPage collection(String id, Object? root) {
    Object? header;
    for (final key in ['musicResponsiveHeaderRenderer', 'musicDetailHeaderRenderer', 'musicEditablePlaylistDetailHeaderRenderer']) {
      header = _findAll(root, key).firstOrNull;
      if (header != null) break;
    }
    final subtitle = _parts(_at(header, ['subtitle']));
    final kind = subtitle.isNotEmpty && !_year.hasMatch(subtitle.first) ? subtitle.first : null;
    final year = subtitle.isNotEmpty && _year.hasMatch(subtitle.last) ? subtitle.last : null;
    final strapline = _runs(_at(header, ['straplineTextOne']));
    // An album names its artist under the title; a playlist names whoever made it beside a small picture
    final named = strapline.map((r) => _string(_at(r, ['text'])) ?? '').join();
    final owner = named.isNotEmpty ? named : _string(_at(header, ['facepile', 'avatarStackViewModel', 'text', 'content']));
    String? ownerId;
    for (final run in strapline) {
      final page = _string(_at(run, ['navigationEndpoint', 'browseEndpoint', 'browseId']));
      if (page != null && page.startsWith('UC')) {
        ownerId = page;
        break;
      }
    }
    final shelf = _findAll(root, 'musicPlaylistShelfRenderer').firstOrNull ?? _findAll(root, 'musicShelfRenderer').firstOrNull;
    final rows = _elements(_at(shelf, ['contents']));
    final isAlbum = id.startsWith('MPRE') || _albumKinds.contains(kind);
    final title = _text(_at(header, ['title'])) ?? '';
    final cover = _thumbnail(_at(header, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']));
    final tracks = [
      for (final row in rows)
        if (_listRow(row, show: title) case final song?)
          if (!isAlbum)
            song
          else
            // The rows of an album leave out what the page says once: whose songs they are, which album and its cover
            _track(
              song,
              thumb: song.thumb ?? cover,
              artist: song.artist.trim().isEmpty ? (owner ?? '') : song.artist,
              artistId: song.artistId ?? (song.artist.trim().isEmpty ? ownerId : null),
              album: song.album ?? title,
              albumId: song.albumId ?? (id.startsWith('MPRE') ? id : null),
              year: song.year ?? year,
            ),
    ];
    return CollectionPage(
      id: id,
      title: title,
      kind: kind,
      year: year,
      owner: owner,
      ownerId: ownerId,
      description: _text(_at(header, ['description', 'musicDescriptionShelfRenderer', 'description'])),
      thumb: cover,
      stats: _parts(_at(header, ['secondSubtitle'])),
      tracks: tracks,
      more: shelf == null ? null : _shelfToken(shelf),
      shelves: [
        for (final s in _findAll(root, 'musicCarouselShelfRenderer')) ?_carousel(s),
      ],
    );
  }

  /// A row of a list of songs: a song or video, or an episode of a podcast, which has a row of its own kind.
  static MusicTrack? _listRow(Object? row, {String show = ''}) =>
      _listTrack(_at(row, ['musicResponsiveListItemRenderer'])) ?? _episode(_at(row, ['musicMultiRowListItemRenderer']), show);

  /// An episode in the list of a podcast show. Its row does not say which show it is of, so the page's name is given.
  static MusicTrack? _episode(Object? row, String show) {
    if (row == null) return null;
    final videoId = _string(_at(row, ['onTap', 'watchEndpoint', 'videoId']));
    final title = _text(_at(row, ['title']));
    if (videoId == null || title == null) return null;
    return MusicTrack(
      videoId: videoId,
      title: title,
      artist: show,
      durMs: _spokenSeconds(_text(_at(row, ['playbackProgress', 'musicPlaybackProgressRenderer', 'durationText']))) * 1000,
      thumb: _thumbnail(_at(row, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
    );
  }

  /// What comes after the first songs of a long playlist.
  static MoreTracks continuation(Object? root) {
    final shelf = _at(root, ['continuationContents', 'musicPlaylistShelfContinuation']) ??
        _at(root, ['continuationContents', 'musicShelfContinuation']);
    var items = _elements(_at(root, ['onResponseReceivedActions', '0', 'appendContinuationItemsAction', 'continuationItems']));
    if (items.isEmpty) items = _elements(_at(shelf, ['contents']));
    return MoreTracks(
      tracks: [for (final i in items) ?_listRow(i)],
      more: _continuationToken(items) ?? (shelf == null ? null : _shelfToken(shelf)),
    );
  }

  static String? _continuationToken(List<Object?> items) {
    for (final item in items) {
      final token = _string(_at(item, ['continuationItemRenderer', 'continuationEndpoint', 'continuationCommand', 'token']));
      if (token != null) return token;
    }
    return null;
  }

  /// What a search gave, as tracks; results that are not a song or video (artists, albums) are skipped.
  static List<MusicTrack> search(Object? root) => [
    for (final row in _findAll(root, 'musicResponsiveListItemRenderer')) ?_listTrack(row),
  ];

  /// The shelves of the home page that hold songs or playlists.
  static List<MusicShelf> shelves(Object? root) => [
    for (final shelf in _findAll(root, 'musicCarouselShelfRenderer')) ?_shelfOfSongs(shelf),
  ];

  static MusicShelf? _shelfOfSongs(Object? shelf) {
    final items = _elements(_at(shelf, ['contents']));
    final tracks = [for (final i in items) ?_listTrack(_at(i, ['musicResponsiveListItemRenderer']))];
    final playlists = [for (final i in items) ?_playlistCard(_at(i, ['musicTwoRowItemRenderer']))];
    final title = _text(_at(shelf, ['header', 'musicCarouselShelfBasicHeaderRenderer', 'title']));
    return title == null || (tracks.isEmpty && playlists.isEmpty) ? null : MusicShelf(title: title, tracks: tracks, playlists: playlists);
  }

  /// The moods the home page offers, and its shelves of anything (songs, playlists, albums, artists).
  static MusicHome home(Object? root) => MusicHome(
    chips: [
      for (final chip in _findAll(root, 'chipCloudChipRenderer'))
        if (_text(_at(chip, ['text'])) case final label?)
          if (_string(_at(chip, ['navigationEndpoint', 'browseEndpoint', 'params'])) case final params?)
            MoodChip(label: label, params: params),
    ],
    shelves: [for (final s in _findAll(root, 'musicCarouselShelfRenderer')) ?_carousel(s)],
  );

  /// The charts page: its playlists and the list of the artists played most.
  static List<MusicShelf> charts(Object? root) {
    final rows = <MusicShelf>[];
    for (final shelf in _findAll(root, 'musicCarouselShelfRenderer')) {
      final title = _text(_at(shelf, ['header', 'musicCarouselShelfBasicHeaderRenderer', 'title']));
      if (title == null) continue;
      final artists = [
        for (final i in _elements(_at(shelf, ['contents']))) ?_artistRow(_at(i, ['musicResponsiveListItemRenderer'])),
      ];
      if (artists.isNotEmpty) {
        rows.add(MusicShelf(title: title, artists: artists));
      } else if (_carousel(shelf) case final built?) {
        rows.add(built);
      }
    }
    return rows;
  }

  /// A row of a list that names an artist, as the charts list them.
  static ArtistCard? _artistRow(Object? row) {
    if (row == null) return null;
    final id = _string(_at(row, ['navigationEndpoint', 'browseEndpoint', 'browseId']));
    if (id == null || !id.startsWith('UC')) return null;
    final columns = _columns(row);
    final name = _text(columns.firstOrNull);
    if (name == null) return null;
    return ArtistCard(
      id: id,
      name: name,
      subtitle: _text(columns.length > 1 ? columns[1] : null),
      thumb: _thumbnail(_at(row, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
    );
  }

  // ------------------------------------------------------------------ search

  /// What a search found: the top result, the list of the rest, the filters on offer and where more can be had.
  static SearchResults searchPage(Object? root) {
    final chips = [
      for (final chip in _findAll(root, 'chipCloudChipRenderer'))
        if (_text(_at(chip, ['text'])) case final label?)
          if (_string(_at(chip, ['navigationEndpoint', 'searchEndpoint', 'params'])) case final params?)
            SearchChip(label: label, params: params),
    ];
    final card = _findAll(root, 'musicCardShelfRenderer').firstOrNull;
    final top = card == null ? null : _cardItem(card);
    // The songs shown inside the card of the top result are in the list below it too, so they are left out here
    final items = [
      for (final row in _findAll(root, 'musicResponsiveListItemRenderer', skip: 'musicCardShelfRenderer')) ?_searchItem(row),
    ];
    final shelf = _findAll(root, 'musicShelfRenderer').firstOrNull;
    return SearchResults(chips: chips, top: top, items: items, more: shelf == null ? null : _shelfToken(shelf));
  }

  /// The results after the first ones of a search.
  static SearchResults searchMore(Object? root) {
    final shelf = _at(root, ['continuationContents', 'musicShelfContinuation']);
    final items = [
      for (final i in _elements(_at(shelf, ['contents']))) ?_searchItem(_at(i, ['musicResponsiveListItemRenderer'])),
    ];
    return SearchResults(items: items, more: shelf == null ? null : _shelfToken(shelf));
  }

  /// Where the rest of a shelf is asked for, in the older way of saying it or the newer one.
  static String? _shelfToken(Object? shelf) =>
      _string(_at(shelf, ['continuations', '0', 'nextContinuationData', 'continuation'])) ??
      _continuationToken(_elements(_at(shelf, ['contents'])));

  static SearchItem? _searchItem(Object? row) {
    if (row == null) return null;
    final columns = _columns(row);
    final title = _text(columns.firstOrNull);
    if (title == null) return null;
    final byline = _runs(columns.length > 1 ? columns[1] : null);
    final thumb = _thumbnail(_at(row, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']));
    final page = _at(row, ['navigationEndpoint', 'browseEndpoint']);
    final pageId = _string(_at(page, ['browseId']));
    if (pageId != null) {
      return _pageItem(
        pageId,
        _string(_at(page, ['browseEndpointContextSupportedConfigs', 'browseEndpointContextMusicConfig', 'pageType'])),
        title,
        byline,
        thumb,
      );
    }
    final song = _listTrack(row, labelled: true);
    return song == null ? null : _trackItem(song, _videoType(row), byline);
  }

  /// The big card at the top of a search, which is one result like the others.
  static SearchItem? _cardItem(Object? card) {
    final title = _text(_at(card, ['title']));
    if (title == null) return null;
    final byline = _runs(_at(card, ['subtitle']));
    final thumbs = _at(card, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']);
    final endpoint = _at(_runs(_at(card, ['title'])).firstOrNull, ['navigationEndpoint']);
    final pageId = _string(_at(endpoint, ['browseEndpoint', 'browseId']));
    if (pageId != null) {
      final pageType = _string(
        _at(endpoint, ['browseEndpoint', 'browseEndpointContextSupportedConfigs', 'browseEndpointContextMusicConfig', 'pageType']),
      );
      return _pageItem(pageId, pageType, title, byline, _thumbnail(thumbs));
    }
    final watch = _at(endpoint, ['watchEndpoint']);
    final type = _string(_at(watch, ['watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType']));
    String? duration;
    for (final run in byline) {
      final text = _string(_at(run, ['text']))?.trim();
      if (text != null && _duration.hasMatch(text)) duration = text;
    }
    final videoId = _string(_at(watch, ['videoId']));
    if (videoId == null) return null;
    final song = _build(videoId, title, _withoutLabel(byline), duration, thumbs, type);
    return _trackItem(song, type, byline);
  }

  /// A result that opens a page: an artist, a profile, an album or a playlist.
  static SearchItem? _pageItem(String pageId, String? pageType, String title, List<Object?> byline, String? thumb) {
    final label = _labelOf(byline);
    final joined = _groups(_withoutLabel(byline)).join(' · ');
    final rest = joined.isEmpty ? null : joined;
    return switch (pageType) {
      'MUSIC_PAGE_TYPE_ARTIST' => SearchItem(kind: 'artist', id: pageId, title: title, subtitle: rest, label: label, thumb: thumb),
      'MUSIC_PAGE_TYPE_USER_CHANNEL' => SearchItem(kind: 'profile', id: pageId, title: title, subtitle: rest, label: label, thumb: thumb),
      'MUSIC_PAGE_TYPE_ALBUM' => SearchItem(kind: 'album', id: pageId, title: title, subtitle: rest, label: label, thumb: thumb),
      'MUSIC_PAGE_TYPE_PLAYLIST' => SearchItem(
        kind: 'playlist',
        id: pageId.startsWith('VL') ? pageId.substring(2) : pageId,
        title: title,
        subtitle: rest,
        label: label,
        thumb: thumb,
      ),
      'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' => SearchItem(kind: 'playlist', id: pageId, title: title, subtitle: rest, label: label, thumb: thumb),
      _ => null,
    };
  }

  /// A result that plays: a song, a video or an episode of a podcast.
  static SearchItem _trackItem(MusicTrack song, String? type, List<Object?> byline) {
    final label = _labelOf(byline);
    if (type != 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE') {
      return SearchItem(
        kind: song.isSong ? 'song' : 'video',
        id: song.videoId,
        title: song.title,
        label: label,
        thumb: song.thumb,
        track: song,
      );
    }
    // An episode's line is its date and its show, not an artist
    final parts = _groups(_withoutLabel(byline));
    final episode = MusicTrack(
      videoId: song.videoId,
      title: song.title,
      artist: parts.isEmpty ? '' : parts.last,
      durMs: song.durMs,
      thumb: song.thumb,
      album: song.album,
      albumId: song.albumId,
      year: song.year,
      stats: song.stats,
      isSong: song.isSong,
    );
    return SearchItem(
      kind: 'episode',
      id: song.videoId,
      title: song.title,
      subtitle: parts.join(' · '),
      label: label,
      thumb: song.thumb,
      track: episode,
    );
  }

  static const _labels = {'Song', 'Video', 'Episode', 'Podcast', 'Single', 'EP', 'Album', 'Playlist', 'Artist', 'Profile'};

  /// The word at the start of a line like "Single • Artist • 2014" that says what the result is, if there is one.
  static String? _labelOf(List<Object?> runs) {
    if (runs.isEmpty) return null;
    final first = runs.first;
    final text = _string(_at(first, ['text']))?.trim();
    final alone = runs.length == 1 || _string(_at(runs[1], ['text']))?.trim() == '•';
    return text != null && _labels.contains(text) && alone && _at(first, ['navigationEndpoint']) == null ? text : null;
  }

  static List<Object?> _withoutLabel(List<Object?> runs) => _labelOf(runs) != null ? runs.skip(2).toList() : runs;

  /// The pieces of a line of runs between its "•" separators, each one text.
  static List<String> _groups(List<Object?> runs) {
    final out = [StringBuffer()];
    for (final run in runs) {
      final text = _string(_at(run, ['text'])) ?? '';
      if (text.trim() == '•') {
        out.add(StringBuffer());
      } else {
        out.last.write(text);
      }
    }
    return [
      for (final b in out)
        if (b.toString().trim().isNotEmpty) b.toString().trim(),
    ];
  }

  // ------------------------------------------------------------------ items

  /// A song of the queue list, which may come with the other release of it (left out: the app does not show it).
  static MusicTrack? _panelTrack(Object? item) {
    final wrapper = _at(item, ['playlistPanelVideoWrapperRenderer']);
    if (wrapper != null) return _panelRow(_at(wrapper, ['primaryRenderer', 'playlistPanelVideoRenderer']));
    return _panelRow(_at(item, ['playlistPanelVideoRenderer']));
  }

  static MusicTrack? _panelRow(Object? row) {
    if (row == null) return null;
    final videoId = _string(_at(row, ['videoId']));
    final title = _text(_at(row, ['title']));
    if (videoId == null || title == null) return null;
    final type = _string(
      _at(row, ['navigationEndpoint', 'watchEndpoint', 'watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType']),
    );
    return _build(
      videoId,
      title,
      _runs(_at(row, ['longBylineText'])),
      _text(_at(row, ['lengthText'])),
      _at(row, ['thumbnail', 'thumbnails']),
      type,
    );
  }

  /// A row of a list (search result, top songs, related), or null when the row is not a song or video.
  static MusicTrack? _listTrack(Object? row, {bool labelled = false}) {
    if (row == null) return null;
    final videoId = _string(_at(row, ['playlistItemData', 'videoId'])) ??
        _string(
          _at(row, ['overlay', 'musicItemThumbnailOverlayRenderer', 'content', 'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint', 'videoId']),
        );
    if (videoId == null) return null;
    final columns = _columns(row);
    final type = _videoType(row);
    // The length is in a column of its own, or at the end of the second one
    final runs = [
      for (final c in columns.skip(1)) ..._runs(c),
      for (final f in _elements(_at(row, ['fixedColumns'])))
        ..._runs(_at(f, ['musicResponsiveListItemFixedColumnRenderer', 'text'])),
    ];
    String? duration;
    for (final run in runs) {
      final text = _string(_at(run, ['text']))?.trim();
      if (text != null && _duration.hasMatch(text)) duration = text;
    }
    final title = _text(columns.firstOrNull);
    if (title == null) return null;
    final byline = _runs(columns.length > 1 ? columns[1] : null);
    return _build(
      videoId,
      title,
      labelled ? _withoutLabel(byline) : byline,
      duration,
      _at(row, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']),
      type,
    );
  }

  static List<Object?> _columns(Object? row) => [
    for (final c in _elements(_at(row, ['flexColumns']))) _at(c, ['musicResponsiveListItemFlexColumnRenderer', 'text']),
  ];

  /// What kind of video a row plays (`MUSIC_VIDEO_TYPE_ATV` for a song), as the row says it.
  static String? _videoType(Object? row) {
    const config = ['watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType'];
    return _string(
          _at(row, ['overlay', 'musicItemThumbnailOverlayRenderer', 'content', 'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint', ...config]),
        ) ??
        _string(_at(_runs(_columns(row).firstOrNull).firstOrNull, ['navigationEndpoint', 'watchEndpoint', ...config]));
  }

  /// The parts of a line like "Artist • Album • 1987" are told apart by where the separators are.
  static MusicTrack _build(String videoId, String title, List<Object?> byline, String? duration, Object? thumbs, String? type) {
    final parts = <List<Object?>>[[]];
    for (final run in byline) {
      if (_string(_at(run, ['text']))?.trim() == '•') {
        parts.add([]);
      } else {
        parts.last.add(run);
      }
    }
    final artistRuns = parts.first;
    String? pageId(Object? run) => _string(_at(run, ['navigationEndpoint', 'browseEndpoint', 'browseId']));
    final later = parts.skip(1).toList();
    Object? album;
    for (final run in later.expand((p) => p)) {
      if (pageId(run)?.startsWith('MPRE') == true) {
        album = run;
        break;
      }
    }
    final lastPart = later.isEmpty ? null : later.last;
    final yearText = lastPart != null && lastPart.length == 1 ? _string(_at(lastPart.first, ['text'])) : null;
    final year = yearText != null && _year.hasMatch(yearText) ? yearText : null;
    // A video's line says how many watched it instead of which album it is on
    final stats = [
      for (final part in later)
        if (part.map((r) => _string(_at(r, ['text'])) ?? '').join().trim() case final t
            when t.endsWith('views') || t.endsWith('likes') || t.endsWith('plays'))
          t,
    ].join(' · ');
    String? artistId;
    for (final run in artistRuns) {
      final id = pageId(run);
      if (id != null && id.startsWith('UC')) {
        artistId = id;
        break;
      }
    }
    return MusicTrack(
      videoId: videoId,
      title: title,
      artist: artistRuns.map((r) => _string(_at(r, ['text'])) ?? '').join().trim(),
      artistId: artistId,
      album: _string(_at(album, ['text'])),
      albumId: pageId(album),
      year: year,
      durMs: _seconds(duration) * 1000,
      thumb: _thumbnail(thumbs),
      isSong: type == 'MUSIC_VIDEO_TYPE_ATV',
      stats: stats.isEmpty ? null : stats,
    );
  }

  /// [song] with the fields of an album filled in.
  static MusicTrack _track(
    MusicTrack song, {
    String? thumb,
    required String artist,
    String? artistId,
    String? album,
    String? albumId,
    String? year,
  }) => MusicTrack(
    videoId: song.videoId,
    title: song.title,
    artist: artist,
    durMs: song.durMs,
    thumb: thumb,
    artistId: artistId,
    album: album,
    albumId: albumId,
    year: year,
    stats: song.stats,
    isSong: song.isSong,
  );

  static ArtistCard? _artistCard(Object? card) {
    if (card == null) return null;
    final id = _string(_at(card, ['navigationEndpoint', 'browseEndpoint', 'browseId']));
    if (id == null || !id.startsWith('UC')) return null;
    return ArtistCard(
      id: id,
      name: _text(_at(card, ['title'])) ?? '',
      subtitle: _text(_at(card, ['subtitle'])),
      thumb: _thumbnail(_at(card, ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
    );
  }

  static Release? _albumCard(Object? card) {
    if (card == null) return null;
    final id = _string(_at(card, ['navigationEndpoint', 'browseEndpoint', 'browseId']));
    if (id == null || !id.startsWith('MPRE')) return null;
    return Release(
      id: id,
      title: _text(_at(card, ['title'])) ?? '',
      subtitle: _text(_at(card, ['subtitle'])),
      thumb: _thumbnail(_at(card, ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
    );
  }

  static Release? _playlistCard(Object? card) {
    if (card == null) return null;
    var id = _string(_at(card, ['navigationEndpoint', 'browseEndpoint', 'browseId']));
    if (id == null) return null;
    if (id.startsWith('VL')) id = id.substring(2);
    if (!(id.startsWith('PL') || id.startsWith('RD') || id.startsWith('OLAK'))) return null;
    return Release(
      id: id,
      title: _text(_at(card, ['title'])) ?? '',
      subtitle: _text(_at(card, ['subtitle'])),
      thumb: _thumbnail(_at(card, ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
    );
  }

  /// A row of cards that scrolls sideways, whatever the cards are; null when it has no name or nothing in it.
  static MusicShelf? _carousel(Object? shelf) {
    final title = _text(_at(shelf, ['header', 'musicCarouselShelfBasicHeaderRenderer', 'title']));
    if (title == null) return null;
    final tracks = <MusicTrack>[];
    final playlists = <Release>[];
    final albums = <Release>[];
    final artists = <ArtistCard>[];
    for (final item in _elements(_at(shelf, ['contents']))) {
      final card = _at(item, ['musicTwoRowItemRenderer']);
      final listed = _listTrack(_at(item, ['musicResponsiveListItemRenderer']));
      if (listed != null) {
        tracks.add(listed);
        continue;
      }
      final video = _videoCard(card);
      if (video != null) {
        tracks.add(video);
        continue;
      }
      final artist = _artistCard(card);
      if (artist != null) {
        artists.add(artist);
        continue;
      }
      final album = _albumCard(card);
      if (album != null) {
        albums.add(album);
        continue;
      }
      final list = _playlistCard(card);
      if (list != null) playlists.add(list);
    }
    if (tracks.isEmpty && playlists.isEmpty && albums.isEmpty && artists.isEmpty) return null;
    return MusicShelf(title: title, tracks: tracks, playlists: playlists, albums: albums, artists: artists);
  }

  /// A card of a video, which opens the video instead of a page.
  static MusicTrack? _videoCard(Object? card) {
    if (card == null) return null;
    final watch = _at(card, ['navigationEndpoint', 'watchEndpoint']);
    final videoId = _string(_at(watch, ['videoId']));
    final title = _text(_at(card, ['title']));
    if (videoId == null || title == null) return null;
    return _build(
      videoId,
      title,
      _runs(_at(card, ['subtitle'])),
      null,
      _at(card, ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']),
      _string(_at(watch, ['watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType'])),
    );
  }

  // ------------------------------------------------------------------ reading

  static const _albumKinds = {'Album', 'Single', 'EP'};

  static final _duration = RegExp(r'^\d{1,2}(:\d{2}){1,2}$');
  static final _year = RegExp(r'^\d{4}$');
  static final _hours = RegExp(r'(\d+)\s*hr');
  static final _minutes = RegExp(r'(\d+)\s*min');
  static final _secondsRe = RegExp(r'(\d+)\s*sec');
  static final _size = RegExp(r'=w\d+-h\d+');

  /// "3:34" or "1:02:03" in seconds; 0 for anything else.
  static int _seconds(String? text) {
    if (text == null || !_duration.hasMatch(text)) return 0;
    return text.split(':').fold(0, (total, part) => total * 60 + int.parse(part));
  }

  /// "1 hr 1 min", "29 min" or "45 sec" in seconds; 0 for anything else.
  static int _spokenSeconds(String? text) {
    if (text == null) return 0;
    int of(RegExp unit) => int.tryParse(unit.firstMatch(text)?.group(1) ?? '') ?? 0;
    return of(_hours) * 3600 + of(_minutes) * 60 + of(_secondsRe);
  }

  /// The biggest picture of a list, and in a size fit for a cover: YouTube serves any square size by its address.
  static String? _thumbnail(Object? thumbs) {
    Object? widest;
    var best = -1;
    for (final t in _elements(thumbs)) {
      final width = int.tryParse(_string(_at(t, ['width'])) ?? '') ?? 0;
      if (width > best) {
        best = width;
        widest = t;
      }
    }
    final url = _string(_at(widest, ['url']));
    if (url == null) return null;
    return url.contains('googleusercontent.com') ? url.replaceAll(_size, '=w544-h544') : url;
  }

  /// The element under [path], where each step is a key of an object or a position in a list.
  static Object? _at(Object? node, List<String> path) {
    var current = node;
    for (final step in path) {
      current = switch (current) {
        Map() => current[step],
        List() => switch (int.tryParse(step)) {
          final i? when i >= 0 && i < current.length => current[i],
          _ => null,
        },
        _ => null,
      };
      if (current == null) return null;
    }
    return current;
  }

  /// The text of a primitive, as Kotlin's `contentOrNull` gives it.
  static String? _string(Object? node) => switch (node) {
    String() => node,
    num() || bool() => '$node',
    _ => null,
  };

  static List<Object?> _elements(Object? node) => node is List ? List<Object?>.from(node) : const [];

  static List<Object?> _runs(Object? node) => _elements(_at(node, ['runs']));

  /// The pieces of a line like "18 songs • 1 hour, 13 minutes", without the separators.
  static List<String> _parts(Object? node) => _groups(_runs(node));

  /// The text of a run list joined, like the title of a shelf.
  static String? _text(Object? node) {
    final text = _runs(node).map((r) => _string(_at(r, ['text'])) ?? '').join();
    return text.isEmpty ? null : text;
  }

  /// Every value under [key], wherever it is in the tree.
  static List<Object?> _findAll(Object? node, String key, {String? skip}) {
    final found = <Object?>[];
    void walk(Object? n) {
      if (n is Map) {
        n.forEach((k, v) {
          if (k == key) {
            found.add(v);
          } else if (k != skip) {
            walk(v);
          }
        });
      } else if (n is List) {
        n.forEach(walk);
      }
    }

    walk(node);
    return found;
  }
}
