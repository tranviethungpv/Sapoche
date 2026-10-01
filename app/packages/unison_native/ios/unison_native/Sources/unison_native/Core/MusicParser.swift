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
        let topSongs = (root.findAll("musicShelfRenderer").first?.at("contents").array ?? [])
            .compactMap { listTrack($0.at("musicResponsiveListItemRenderer")) }
        var albums: [AlbumCard] = []
        var singles: [AlbumCard] = []
        var similar: [ArtistCard] = []
        for shelf in root.findAll("musicCarouselShelfRenderer") {
            let title = shelf.at("header", "musicCarouselShelfBasicHeaderRenderer", "title").text
            for item in shelf.at("contents").array {
                let card = item.at("musicTwoRowItemRenderer")
                if let artist = artistCard(card) {
                    similar.append(artist)
                } else if let album = albumCard(card) {
                    if title == "Albums" { albums.append(album) } else if title == "Singles & EPs" { singles.append(album) }
                }
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
            similar: similar
        )
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
    private static func listTrack(_ row: JSON?) -> MusicTrack? {
        guard let row, !row.isNull else { return nil }
        guard let videoId = row.at("playlistItemData", "videoId").string
                ?? row.at("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId").string
        else { return nil }
        let columns = row.at("flexColumns").array.map { $0.at("musicResponsiveListItemFlexColumnRenderer", "text") }
        let type = row.at("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string
            ?? columns.first?.runs.first?.at("navigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string
        // The length is in a column of its own, or at the end of the second one
        let candidates = columns.dropFirst().flatMap { $0.runs }
            + row.at("fixedColumns").array.flatMap { $0.at("musicResponsiveListItemFixedColumnRenderer", "text").runs }
        let duration = candidates.compactMap { $0.at("text").string?.trimmingCharacters(in: .whitespaces) }.last { isDuration($0) }
        guard let title = columns.first?.text else { return nil }
        return track(
            videoId: videoId,
            title: title,
            byline: columns.count > 1 ? columns[1].runs : [],
            duration: duration,
            thumbs: row.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
            type: type
        )
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

    /// The text of a run list joined, like the title of a shelf.
    fileprivate var text: String? {
        let joined = runs.map { $0.at("text").string ?? "" }.joined()
        return joined.isEmpty ? nil : joined
    }
}
