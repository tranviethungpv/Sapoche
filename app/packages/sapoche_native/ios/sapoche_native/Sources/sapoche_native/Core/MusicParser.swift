import Foundation

/// Reads the answers of YouTube Music. Their shape is not promised to anybody, so every read goes through
/// [JSON.at] and gives nil or nothing for what is missing, and whatever is left after that is still shown.
enum MusicParser {

    static func watchNext(_ root: JSON) -> WatchNext {
        let tabs = root.at("contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs")
            .array.map { $0.at("tabRenderer") }
        let queue = tabs.first.map {
            $0.at("content", "musicQueueRenderer", "content", "playlistPanelRenderer", "contents").array.compactMap(panelTrack)
        } ?? []
        // A tab is only there to open when it has a page to go to
        func pageOf(_ title: String) -> String? {
            tabs.first { $0.at("title").string == title }?.at("endpoint", "browseEndpoint", "browseId").string
        }
        return WatchNext(tracks: queue, lyricsId: pageOf("Lyrics"), relatedId: pageOf("Related"))
    }

    static func related(_ root: JSON) -> Related {
        var more: [MusicTrack] = []
        var other: [MusicTrack] = []
        var artists: [ArtistCard] = []
        var playlists: [PlaylistCard] = []
        for shelf in root.findAll("musicCarouselShelfRenderer") {
            let title = shelf.at("header", "musicCarouselShelfBasicHeaderRenderer", "title").text
            let items = shelf.at("contents").array
            let tracks = items.compactMap { listTrack($0.at("musicResponsiveListItemRenderer")) }
            if !tracks.isEmpty && title == "Other performances" {
                other = tracks
            } else if !tracks.isEmpty && more.isEmpty {
                more = tracks
            } else {
                for item in items {
                    let card = item.at("musicTwoRowItemRenderer")
                    if let artist = artistCard(card) {
                        artists.append(artist)
                    } else if let playlist = playlistCard(card) {
                        playlists.append(playlist)
                    }
                }
            }
        }
        let about = root.findAll("musicDescriptionShelfRenderer").first?.at("description").text
        return Related(more: more, otherPerformances: other, artists: artists, playlists: playlists, about: about)
    }

    static func lyrics(_ root: JSON) -> String? {
        let text = root.findAll("musicDescriptionShelfRenderer").first?.at("description").text
        return text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    static func artist(_ id: String, _ root: JSON) -> ArtistPage {
        let header = root.at("header").at("musicImmersiveHeaderRenderer").isNull
            ? root.at("header").at("musicVisualHeaderRenderer")
            : root.at("header").at("musicImmersiveHeaderRenderer")
        let topShelf = root.findAll("musicShelfRenderer").first
        let topSongs = (topShelf?.at("contents").array ?? [])
            .compactMap { listTrack($0.at("musicResponsiveListItemRenderer")) }
        var topSongsId = topShelf?.at("title", "runs", "0", "navigationEndpoint", "browseEndpoint", "browseId").string
        if topSongsId == nil { topSongsId = topShelf?.at("bottomEndpoint", "browseEndpoint", "browseId").string }
        if let id = topSongsId, id.hasPrefix("VL") { topSongsId = String(id.dropFirst(2)) }
        var albums: [AlbumCard] = []
        var singles: [AlbumCard] = []
        var similar: [ArtistCard] = []
        var others: [MusicShelf] = []
        for shelf in root.findAll("musicCarouselShelfRenderer") {
            guard let built = carousel(shelf) else { continue }
            if built.title == "Albums" {
                albums += built.albums
            } else if built.title == "Singles & EPs" {
                singles += built.albums
            } else if !built.artists.isEmpty && built.tracks.isEmpty && built.albums.isEmpty && built.playlists.isEmpty {
                similar += built.artists
            } else {
                others.append(built)
            }
        }
        return ArtistPage(
            id: id,
            name: header.at("title").text ?? "",
            description: header.at("description").text,
            subscribers: header.at("subscriptionButton", "subscribeButtonRenderer", "subscriberCountText").text,
            thumbUrl: thumbnail(header.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails")),
            topSongs: topSongs,
            albums: albums,
            singles: singles,
            similar: similar,
            shelves: others,
            topSongsId: topSongsId
        )
    }

    /// An album or a playlist page: the header, the first songs and the rows below them.
    static func collection(_ id: String, _ root: JSON) -> CollectionPage {
        let header = ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer", "musicEditablePlaylistDetailHeaderRenderer"]
            .compactMap { root.findAll($0).first }.first ?? JSON(nil)
        let subtitle = header.at("subtitle").parts
        let kind = subtitle.first.flatMap { isYear($0) ? nil : $0 }
        let year = subtitle.last.flatMap { isYear($0) ? $0 : nil }
        let strapline = header.at("straplineTextOne").runs
        // An album names its artist under the title; a playlist names whoever made it beside a small picture
        let named = strapline.map { $0.at("text").string ?? "" }.joined()
        let owner = named.isEmpty ? header.at("facepile", "avatarStackViewModel", "text", "content").string : named
        let ownerId = strapline.compactMap { $0.at("navigationEndpoint", "browseEndpoint", "browseId").string }.first { $0.hasPrefix("UC") }
        let shelf = root.findAll("musicPlaylistShelfRenderer").first ?? root.findAll("musicShelfRenderer").first
        let rows = shelf?.at("contents").array ?? []
        let isAlbum = id.hasPrefix("MPRE") || ["Album", "Single", "EP"].contains(kind ?? "")
        let title = header.at("title").text ?? ""
        let cover = thumbnail(header.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"))
        let tracks = rows.compactMap { listTrack($0.at("musicResponsiveListItemRenderer")) }.map { song -> MusicTrack in
            // The rows of an album leave out what the page says once: whose songs they are, which album and its cover
            guard isAlbum else { return song }
            let anonymous = song.artist.isEmpty
            return MusicTrack(
                videoId: song.videoId, title: song.title, artist: anonymous ? owner ?? "" : song.artist,
                artistId: song.artistId ?? (anonymous ? ownerId : nil), album: song.album ?? title,
                albumId: song.albumId ?? (id.hasPrefix("MPRE") ? id : nil), year: song.year ?? year,
                durationSec: song.durationSec, thumbUrl: song.thumbUrl ?? cover, isSong: song.isSong, stats: song.stats,
                counterpart: song.counterpart
            )
        }
        return CollectionPage(
            id: id,
            title: title,
            kind: kind,
            year: year,
            owner: owner,
            ownerId: ownerId,
            description: header.at("description", "musicDescriptionShelfRenderer", "description").text,
            thumbUrl: cover,
            stats: header.at("secondSubtitle").parts,
            tracks: tracks,
            more: continuationToken(rows),
            shelves: root.findAll("musicCarouselShelfRenderer").compactMap(carousel)
        )
    }

    /// What comes after the first songs of a long playlist.
    static func continuation(_ root: JSON) -> Continuation {
        var items = root.at("onResponseReceivedActions", "0", "appendContinuationItemsAction", "continuationItems").array
        if items.isEmpty { items = root.at("continuationContents", "musicPlaylistShelfContinuation", "contents").array }
        return Continuation(tracks: items.compactMap { listTrack($0.at("musicResponsiveListItemRenderer")) }, more: continuationToken(items))
    }

    private static func continuationToken(_ items: [JSON]) -> String? {
        items.compactMap { $0.at("continuationItemRenderer", "continuationEndpoint", "continuationCommand", "token").string }.first
    }

    /// What a search gave, as tracks; results that are not a song or video (artists, albums) are skipped.
    static func search(_ root: JSON) -> [MusicTrack] {
        root.findAll("musicResponsiveListItemRenderer").compactMap { listTrack($0) }
    }

    /// The songs of a playlist page, and what the playlist is called.
    static func playlist(_ root: JSON) -> (title: String?, tracks: [MusicTrack]) {
        let header = ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer", "musicEditablePlaylistDetailHeaderRenderer"]
            .compactMap { root.findAll($0).first }.first
        return (header?.at("title").text, search(root))
    }

    /// The shelves of the home page that hold songs or playlists.
    static func shelves(_ root: JSON) -> [MusicShelf] {
        root.findAll("musicCarouselShelfRenderer").compactMap { shelf in
            let items = shelf.at("contents").array
            let tracks = items.compactMap { listTrack($0.at("musicResponsiveListItemRenderer")) }
            let playlists = items.compactMap { playlistCard($0.at("musicTwoRowItemRenderer")) }
            guard let title = shelf.at("header", "musicCarouselShelfBasicHeaderRenderer", "title").text,
                  !(tracks.isEmpty && playlists.isEmpty) else { return nil }
            return MusicShelf(title: title, tracks: tracks, playlists: playlists)
        }
    }

    /// The moods the home page offers, and its shelves of anything (songs, playlists, albums, artists).
    static func home(_ root: JSON) -> MusicHome {
        let chips = root.findAll("chipCloudChipRenderer").compactMap { chip -> MoodChip? in
            guard let label = chip.at("text").text, let params = chip.at("navigationEndpoint", "browseEndpoint", "params").string else { return nil }
            return MoodChip(label: label, params: params)
        }
        return MusicHome(chips: chips, shelves: root.findAll("musicCarouselShelfRenderer").compactMap(carousel))
    }

    /// The charts page: its playlists and the list of the artists played most.
    static func charts(_ root: JSON) -> [MusicShelf] {
        root.findAll("musicCarouselShelfRenderer").compactMap { shelf in
            guard let title = shelf.at("header", "musicCarouselShelfBasicHeaderRenderer", "title").text else { return nil }
            let artists = shelf.at("contents").array.compactMap { artistRow($0.at("musicResponsiveListItemRenderer")) }
            return artists.isEmpty ? carousel(shelf) : MusicShelf(title: title, tracks: [], artists: artists)
        }
    }

    /// A row of a list that names an artist, as the charts list them.
    private static func artistRow(_ row: JSON?) -> ArtistCard? {
        guard let row, let id = row.at("navigationEndpoint", "browseEndpoint", "browseId").string, id.hasPrefix("UC") else { return nil }
        let columns = row.at("flexColumns").array.map { $0.at("musicResponsiveListItemFlexColumnRenderer", "text") }
        guard let name = columns.first?.text else { return nil }
        return ArtistCard(id: id, name: name, subtitle: columns.count > 1 ? columns[1].text : nil,
                          thumbUrl: thumbnail(row.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails")))
    }

    // ------------------------------------------------------------------ search

    /// What a search found: the top result, the list of the rest, the filters on offer and where more can be had.
    static func searchPage(_ root: JSON) -> SearchPage {
        let chips = root.findAll("chipCloudChipRenderer").compactMap { chip -> SearchChip? in
            guard let label = chip.at("text").text, let params = chip.at("navigationEndpoint", "searchEndpoint", "params").string else { return nil }
            return SearchChip(label: label, params: params)
        }
        let top = root.findAll("musicCardShelfRenderer").first.flatMap(cardItem)
        // The songs shown inside the card of the top result are in the list below it too, so they are left out here
        let items = root.findAll("musicResponsiveListItemRenderer", skipping: "musicCardShelfRenderer").compactMap(searchItem)
        return SearchPage(chips: chips, top: top, items: items, more: root.findAll("musicShelfRenderer").first.flatMap(searchToken))
    }

    /// The results after the first ones of a search.
    static func searchMore(_ root: JSON) -> SearchPage {
        let shelf = root.at("continuationContents", "musicShelfContinuation")
        let items = shelf.at("contents").array.compactMap { searchItem($0.at("musicResponsiveListItemRenderer")) }
        return SearchPage(chips: [], top: nil, items: items, more: shelf.isNull ? nil : searchToken(shelf))
    }

    private static func searchToken(_ shelf: JSON) -> String? {
        shelf.at("continuations", "0", "nextContinuationData", "continuation").string ?? continuationToken(shelf.at("contents").array)
    }

    private static func searchItem(_ row: JSON?) -> SearchItem? {
        guard let row, !row.isNull else { return nil }
        let columns = row.at("flexColumns").array.map { $0.at("musicResponsiveListItemFlexColumnRenderer", "text") }
        guard let title = columns.first?.text else { return nil }
        let byline = columns.count > 1 ? columns[1].runs : []
        let thumb = thumbnail(row.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"))
        let page = row.at("navigationEndpoint", "browseEndpoint")
        if let pageId = page.at("browseId").string {
            let pageType = page.at("browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType").string
            return pageItem(pageId, pageType, title, byline, thumb)
        }
        guard let song = listTrack(row, labelled: true) else { return nil }
        return trackItem(song, videoType(row), byline)
    }

    /// The big card at the top of a search, which is one result like the others.
    private static func cardItem(_ card: JSON) -> SearchItem? {
        guard let title = card.at("title").text else { return nil }
        let byline = card.at("subtitle").runs
        let thumbs = card.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails")
        let endpoint = card.at("title").runs.first?.at("navigationEndpoint") ?? JSON(nil)
        if let pageId = endpoint.at("browseEndpoint", "browseId").string {
            let pageType = endpoint.at("browseEndpoint", "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType").string
            return pageItem(pageId, pageType, title, byline, thumbnail(thumbs))
        }
        let watch = endpoint.at("watchEndpoint")
        guard let videoId = watch.at("videoId").string else { return nil }
        let type = watch.at("watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string
        let duration = byline.compactMap { $0.at("text").string?.trimmingCharacters(in: .whitespaces) }.last { isDuration($0) }
        let song = track(videoId: videoId, title: title, byline: withoutLabel(byline), duration: duration, thumbs: thumbs, type: type)
        return trackItem(song, type, byline)
    }

    /// A result that opens a page: an artist, a profile, an album or a playlist.
    private static func pageItem(_ pageId: String, _ pageType: String?, _ title: String, _ byline: [JSON], _ thumb: String?) -> SearchItem? {
        let label = labelOf(byline)
        let joined = groups(withoutLabel(byline)).joined(separator: " · ")
        let rest = joined.isEmpty ? nil : joined
        switch pageType {
        case "MUSIC_PAGE_TYPE_ARTIST": return SearchItem(kind: "artist", id: pageId, title: title, subtitle: rest, label: label, thumbUrl: thumb)
        case "MUSIC_PAGE_TYPE_USER_CHANNEL": return SearchItem(kind: "profile", id: pageId, title: title, subtitle: rest, label: label, thumbUrl: thumb)
        case "MUSIC_PAGE_TYPE_ALBUM": return SearchItem(kind: "album", id: pageId, title: title, subtitle: rest, label: label, thumbUrl: thumb)
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            let id = pageId.hasPrefix("VL") ? String(pageId.dropFirst(2)) : pageId
            return SearchItem(kind: "playlist", id: id, title: title, subtitle: rest, label: label, thumbUrl: thumb)
        case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE":
            return SearchItem(kind: "playlist", id: pageId, title: title, subtitle: rest, label: label, thumbUrl: thumb)
        default: return nil
        }
    }

    /// A result that plays: a song, a video or an episode of a podcast.
    private static func trackItem(_ song: MusicTrack, _ type: String?, _ byline: [JSON]) -> SearchItem {
        let label = labelOf(byline)
        guard type == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" else {
            return SearchItem(kind: song.isSong ? "song" : "video", id: song.videoId, title: song.title, subtitle: nil, label: label,
                              thumbUrl: song.thumbUrl, track: song)
        }
        // An episode's line is its date and its show, not an artist
        let parts = groups(withoutLabel(byline))
        let episode = MusicTrack(videoId: song.videoId, title: song.title, artist: parts.last ?? "", album: song.album, albumId: song.albumId,
                                 year: song.year, durationSec: song.durationSec, thumbUrl: song.thumbUrl, isSong: false, stats: song.stats,
                                 counterpart: song.counterpart)
        return SearchItem(kind: "episode", id: song.videoId, title: song.title, subtitle: parts.joined(separator: " · "), label: label,
                          thumbUrl: song.thumbUrl, track: episode)
    }

    private static let labels: Set<String> = ["Song", "Video", "Episode", "Podcast", "Single", "EP", "Album", "Playlist", "Artist", "Profile"]

    /// The word at the start of a line like "Single • Artist • 2014" that says what the result is, if there is one.
    private static func labelOf(_ runs: [JSON]) -> String? {
        guard let first = runs.first, let text = first.at("text").string?.trimmingCharacters(in: .whitespaces) else { return nil }
        let alone = runs.count == 1 || runs[1].at("text").string?.trimmingCharacters(in: .whitespaces) == "•"
        return labels.contains(text) && alone && first.at("navigationEndpoint").isNull ? text : nil
    }

    private static func withoutLabel(_ runs: [JSON]) -> [JSON] { labelOf(runs) == nil ? runs : Array(runs.dropFirst(2)) }

    /// The pieces of a line of runs between its "•" separators, each one text.
    fileprivate static func groups(_ runs: [JSON]) -> [String] {
        var out: [String] = [""]
        for run in runs {
            let text = run.at("text").string ?? ""
            if text.trimmingCharacters(in: .whitespaces) == "•" { out.append("") } else { out[out.count - 1] += text }
        }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // ------------------------------------------------------------------ items

    /// A song of the queue list, which may come with the other release of it.
    private static func panelTrack(_ item: JSON) -> MusicTrack? {
        let wrapper = item.at("playlistPanelVideoWrapperRenderer")
        if !wrapper.isNull {
            guard let primary = panelRow(wrapper.at("primaryRenderer", "playlistPanelVideoRenderer")) else { return nil }
            let other = panelRow(wrapper.at("counterpart").array.first?.at("counterpartRenderer", "playlistPanelVideoRenderer"))
            return primary.with(counterpart: other)
        }
        return panelRow(item.at("playlistPanelVideoRenderer"))
    }

    private static func panelRow(_ row: JSON?) -> MusicTrack? {
        guard let row, let videoId = row.at("videoId").string else { return nil }
        let type = row.at("navigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string
        guard let title = row.at("title").text else { return nil }
        return track(
            videoId: videoId,
            title: title,
            byline: row.at("longBylineText").runs,
            duration: row.at("lengthText").text,
            thumbs: row.at("thumbnail", "thumbnails"),
            type: type
        )
    }

    /// A row of a list (search result, top songs, related), or nil when the row is not a song or video.
    private static func listTrack(_ row: JSON?, labelled: Bool = false) -> MusicTrack? {
        guard let row, !row.isNull else { return nil }
        guard let videoId = row.at("playlistItemData", "videoId").string
                ?? row.at("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId").string
        else { return nil }
        let columns = row.at("flexColumns").array.map { $0.at("musicResponsiveListItemFlexColumnRenderer", "text") }
        let type = videoType(row)
        // The length is in a column of its own, or at the end of the second one
        let candidates = columns.dropFirst().flatMap { $0.runs }
            + row.at("fixedColumns").array.flatMap { $0.at("musicResponsiveListItemFixedColumnRenderer", "text").runs }
        let duration = candidates.compactMap { $0.at("text").string?.trimmingCharacters(in: .whitespaces) }.last { isDuration($0) }
        guard let title = columns.first?.text else { return nil }
        return track(
            videoId: videoId,
            title: title,
            byline: columns.count > 1 ? (labelled ? withoutLabel(columns[1].runs) : columns[1].runs) : [],
            duration: duration,
            thumbs: row.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
            type: type
        )
    }

    /// What kind of video a row plays (`MUSIC_VIDEO_TYPE_ATV` for a song), as the row says it.
    private static func videoType(_ row: JSON) -> String? {
        let columns = row.at("flexColumns").array.map { $0.at("musicResponsiveListItemFlexColumnRenderer", "text") }
        return row.at("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string
            ?? columns.first?.runs.first?.at("navigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string
    }

    /// The parts of a line like "Artist • Album • 1987" are told apart by where the separators are.
    private static func track(videoId: String, title: String, byline: [JSON], duration: String?, thumbs: JSON?, type: String?) -> MusicTrack {
        var parts: [[JSON]] = [[]]
        for run in byline {
            if run.at("text").string?.trimmingCharacters(in: .whitespaces) == "•" {
                parts.append([])
            } else {
                parts[parts.count - 1].append(run)
            }
        }
        let artistRuns = parts[0]
        func pageId(_ run: JSON?) -> String? { run?.at("navigationEndpoint", "browseEndpoint", "browseId").string }
        let later = Array(parts.dropFirst())
        let album = later.flatMap { $0 }.first { pageId($0)?.hasPrefix("MPRE") == true }
        var year: String?
        if let last = later.last, last.count == 1, let text = last[0].at("text").string, isYear(text) { year = text }
        // A video's line says how many watched it instead of which album it is on
        let stats = later
            .map { part in part.map { $0.at("text").string ?? "" }.joined().trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix("views") || $0.hasSuffix("likes") || $0.hasSuffix("plays") }
            .joined(separator: " · ")
        return MusicTrack(
            videoId: videoId,
            title: title,
            artist: artistRuns.map { $0.at("text").string ?? "" }.joined().trimmingCharacters(in: .whitespaces),
            artistId: artistRuns.compactMap { pageId($0) }.first { $0.hasPrefix("UC") },
            album: album?.at("text").string,
            albumId: pageId(album),
            year: year,
            durationSec: seconds(duration),
            thumbUrl: thumbnail(thumbs),
            isSong: type == "MUSIC_VIDEO_TYPE_ATV",
            stats: stats.isEmpty ? nil : stats
        )
    }

    private static func artistCard(_ card: JSON?) -> ArtistCard? {
        guard let card, let id = card.at("navigationEndpoint", "browseEndpoint", "browseId").string, id.hasPrefix("UC") else { return nil }
        return ArtistCard(id: id, name: card.at("title").text ?? "", subtitle: card.at("subtitle").text,
                          thumbUrl: thumbnail(card.at("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails")))
    }

    private static func albumCard(_ card: JSON?) -> AlbumCard? {
        guard let card, let id = card.at("navigationEndpoint", "browseEndpoint", "browseId").string, id.hasPrefix("MPRE") else { return nil }
        return AlbumCard(id: id, title: card.at("title").text ?? "", subtitle: card.at("subtitle").text,
                         thumbUrl: thumbnail(card.at("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails")))
    }

    private static func playlistCard(_ card: JSON?) -> PlaylistCard? {
        guard let card, var id = card.at("navigationEndpoint", "browseEndpoint", "browseId").string else { return nil }
        if id.hasPrefix("VL") { id.removeFirst(2) }
        guard id.hasPrefix("PL") || id.hasPrefix("RD") || id.hasPrefix("OLAK") else { return nil }
        return PlaylistCard(id: id, title: card.at("title").text ?? "", subtitle: card.at("subtitle").text,
                            thumbUrl: thumbnail(card.at("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails")))
    }

    /// A row of cards that scrolls sideways, whatever the cards are; nil when it has no name or nothing in it.
    private static func carousel(_ shelf: JSON) -> MusicShelf? {
        guard let title = shelf.at("header", "musicCarouselShelfBasicHeaderRenderer", "title").text else { return nil }
        var built = MusicShelf(title: title, tracks: [])
        var tracks: [MusicTrack] = []
        for item in shelf.at("contents").array {
            let card = item.at("musicTwoRowItemRenderer")
            if let song = listTrack(item.at("musicResponsiveListItemRenderer")) ?? videoCard(card) {
                tracks.append(song)
            } else if let artist = artistCard(card) {
                built.artists.append(artist)
            } else if let album = albumCard(card) {
                built.albums.append(album)
            } else if let playlist = playlistCard(card) {
                built.playlists.append(playlist)
            }
        }
        built = MusicShelf(title: title, tracks: tracks, playlists: built.playlists, albums: built.albums, artists: built.artists)
        return tracks.isEmpty && built.playlists.isEmpty && built.albums.isEmpty && built.artists.isEmpty ? nil : built
    }

    /// A card of a video, which opens the video instead of a page.
    private static func videoCard(_ card: JSON?) -> MusicTrack? {
        guard let card, !card.isNull else { return nil }
        let watch = card.at("navigationEndpoint", "watchEndpoint")
        guard let videoId = watch.at("videoId").string, let title = card.at("title").text else { return nil }
        return track(
            videoId: videoId,
            title: title,
            byline: card.at("subtitle").runs,
            duration: nil,
            thumbs: card.at("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
            type: watch.at("watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string
        )
    }

    // ------------------------------------------------------------------ reading

    /// "3:34" or "1:02:03": one or two digits, then one or two groups of a colon and two digits.
    static func isDuration(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        for (position, part) in parts.enumerated() {
            let length = part.count
            let fits = position == 0 ? (length == 1 || length == 2) : length == 2
            if !fits || !part.allSatisfy({ $0.isASCII && $0.isNumber }) { return false }
        }
        return true
    }

    private static func isYear(_ text: String) -> Bool {
        text.count == 4 && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// "3:34" or "1:02:03" in seconds; 0 for anything else.
    static func seconds(_ text: String?) -> Int64 {
        guard let text, isDuration(text) else { return 0 }
        return text.split(separator: ":").reduce(Int64(0)) { total, part in total * 60 + (Int64(part) ?? 0) }
    }

    /// The biggest picture of a list, and in a size fit for a cover: YouTube serves any square size by its address.
    private static func thumbnail(_ list: JSON?) -> String? {
        guard let list else { return nil }
        let elements = list.array
        guard var best = elements.first else { return nil }
        for element in elements.dropFirst() where (element.at("width").int ?? 0) > (best.at("width").int ?? 0) { best = element }
        guard let url = best.at("url").string else { return nil }
        guard url.contains("googleusercontent.com"), let size = try? NSRegularExpression(pattern: "=w\\d+-h\\d+") else { return url }
        return size.stringByReplacingMatches(in: url, range: NSRange(url.startIndex..., in: url), withTemplate: "=w544-h544")
    }
}

extension JSON {
    /// The runs of a text, as YouTube Music splits it.
    fileprivate var runs: [JSON] { at("runs").array }

    /// The pieces of a line like "18 songs • 1 hour, 13 minutes", without the separators.
    fileprivate var parts: [String] { MusicParser.groups(runs) }

    /// The text of a run list joined, like the title of a shelf.
    fileprivate var text: String? {
        let joined = runs.map { $0.at("text").string ?? "" }.joined()
        return joined.isEmpty ? nil : joined
    }
}
