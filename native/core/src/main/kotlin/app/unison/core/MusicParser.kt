package app.unison.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Reads the answers of YouTube Music. Their shape is not promised to anybody, so every read goes through
 * [at] and gives null or nothing for what is missing, and whatever is left after that is still shown.
 */
object MusicParser {

    fun watchNext(root: JsonElement): WatchNext {
        val tabs = root.at("contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs")
            .elements()
            .map { it.at("tabRenderer") }
        val queue = tabs.firstOrNull()
            .at("content", "musicQueueRenderer", "content", "playlistPanelRenderer", "contents")
            .elements()
            .mapNotNull { panelTrack(it) }
        // A tab is only there to open when it has a page to go to
        fun pageOf(title: String) = tabs.firstOrNull { it.at("title").string() == title }
            .at("endpoint", "browseEndpoint", "browseId").string()
        return WatchNext(queue, lyricsId = pageOf("Lyrics"), relatedId = pageOf("Related"))
    }

    fun related(root: JsonElement): Related {
        var more: List<MusicTrack> = emptyList()
        var other: List<MusicTrack> = emptyList()
        val artists = ArrayList<ArtistCard>()
        val playlists = ArrayList<PlaylistCard>()
        for (shelf in root.findAll("musicCarouselShelfRenderer")) {
            val title = shelf.at("header", "musicCarouselShelfBasicHeaderRenderer", "title").text()
            val items = shelf.at("contents").elements()
            val tracks = items.mapNotNull { listTrack(it.at("musicResponsiveListItemRenderer")) }
            when {
                tracks.isNotEmpty() && title == "Other performances" -> other = tracks
                tracks.isNotEmpty() && more.isEmpty() -> more = tracks
                else -> for (item in items) {
                    val card = item.at("musicTwoRowItemRenderer")
                    artistCard(card)?.let { artists += it } ?: playlistCard(card)?.let { playlists += it }
                }
            }
        }
        val about = root.findAll("musicDescriptionShelfRenderer").firstOrNull().at("description").text()
        return Related(more, other, artists, playlists, about)
    }

    fun lyrics(root: JsonElement): String? =
        root.findAll("musicDescriptionShelfRenderer").firstOrNull().at("description").text()?.takeIf { it.isNotBlank() }

    fun artist(id: String, root: JsonElement): ArtistPage {
        val header = root.at("header").let { it.at("musicImmersiveHeaderRenderer") ?: it.at("musicVisualHeaderRenderer") }
        val topShelf = root.findAll("musicShelfRenderer").firstOrNull()
        val topSongs = topShelf.at("contents").elements().mapNotNull { listTrack(it.at("musicResponsiveListItemRenderer")) }
        val topSongsId = (topShelf.at("title", "runs", "0", "navigationEndpoint", "browseEndpoint", "browseId") ?: topShelf.at("bottomEndpoint", "browseEndpoint", "browseId"))
            .string()?.removePrefix("VL")
        val albums = ArrayList<AlbumCard>()
        val singles = ArrayList<AlbumCard>()
        val similar = ArrayList<ArtistCard>()
        val others = ArrayList<MusicShelf>()
        for (shelf in root.findAll("musicCarouselShelfRenderer")) {
            val built = carousel(shelf) ?: continue
            when {
                built.title == "Albums" -> albums += built.albums
                built.title == "Singles & EPs" -> singles += built.albums
                built.artists.isNotEmpty() && built.tracks.isEmpty() && built.albums.isEmpty() && built.playlists.isEmpty() -> similar += built.artists
                else -> others += built
            }
        }
        return ArtistPage(
            id = id,
            name = header.at("title").text().orEmpty(),
            description = header.at("description").text(),
            subscribers = header.at("subscriptionButton", "subscribeButtonRenderer", "subscriberCountText").text(),
            thumbUrl = header.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails").thumbnail(),
            topSongs = topSongs,
            albums = albums,
            singles = singles,
            similar = similar,
            shelves = others,
            topSongsId = topSongsId,
        )
    }

    /** An album or a playlist page: the header, the first songs and the rows below them. */
    fun collection(id: String, root: JsonElement): CollectionPage {
        val header = listOf("musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer", "musicEditablePlaylistDetailHeaderRenderer")
            .firstNotNullOfOrNull { root.findAll(it).firstOrNull() }
        val subtitle = header.at("subtitle").parts()
        val kind = subtitle.firstOrNull()?.takeIf { !YEAR.matches(it) }
        val year = subtitle.lastOrNull()?.takeIf { YEAR.matches(it) }
        val strapline = header.at("straplineTextOne").runs()
        // An album names its artist under the title; a playlist names whoever made it beside a small picture
        val owner = strapline.joinToString("") { it.at("text").string().orEmpty() }.takeIf { it.isNotEmpty() }
            ?: header.at("facepile", "avatarStackViewModel", "text", "content").string()
        val ownerId = strapline.firstNotNullOfOrNull { it.at("navigationEndpoint", "browseEndpoint", "browseId").string()?.takeIf { page -> page.startsWith("UC") } }
        val rows = (root.findAll("musicPlaylistShelfRenderer").firstOrNull() ?: root.findAll("musicShelfRenderer").firstOrNull()).at("contents").elements()
        val isAlbum = id.startsWith("MPRE") || kind in ALBUM_KINDS
        val title = header.at("title").text().orEmpty()
        val cover = header.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails").thumbnail()
        val tracks = rows.mapNotNull { listTrack(it.at("musicResponsiveListItemRenderer")) }.map { song ->
            // The rows of an album leave out what the page says once: whose songs they are, which album and its cover
            if (!isAlbum) song else song.copy(
                thumbUrl = song.thumbUrl ?: cover,
                artist = song.artist.ifBlank { owner.orEmpty() },
                artistId = song.artistId ?: ownerId.takeIf { song.artist.isBlank() },
                album = song.album ?: title,
                albumId = song.albumId ?: id.takeIf { it.startsWith("MPRE") },
                year = song.year ?: year,
            )
        }
        return CollectionPage(
            id = id,
            title = title,
            kind = kind,
            year = year,
            owner = owner,
            ownerId = ownerId,
            description = header.at("description", "musicDescriptionShelfRenderer", "description").text(),
            thumbUrl = cover,
            stats = header.at("secondSubtitle").parts(),
            tracks = tracks,
            more = continuationToken(rows),
            shelves = root.findAll("musicCarouselShelfRenderer").mapNotNull { carousel(it) },
        )
    }

    /** What comes after the first songs of a long playlist. */
    fun continuation(root: JsonElement): Continuation {
        val items = root.at("onResponseReceivedActions", "0", "appendContinuationItemsAction", "continuationItems").elements()
            .ifEmpty { root.at("continuationContents", "musicPlaylistShelfContinuation", "contents").elements() }
        return Continuation(items.mapNotNull { listTrack(it.at("musicResponsiveListItemRenderer")) }, continuationToken(items))
    }

    private fun continuationToken(items: List<JsonElement>): String? =
        items.firstNotNullOfOrNull { it.at("continuationItemRenderer", "continuationEndpoint", "continuationCommand", "token").string() }

    /** What a search gave, as tracks; results that are not a song or video (artists, albums) are skipped. */
    fun search(root: JsonElement): List<MusicTrack> =
        root.findAll("musicResponsiveListItemRenderer").mapNotNull { listTrack(it) }

    /** The shelves of the home page that hold songs or playlists. */
    fun shelves(root: JsonElement): List<MusicShelf> =
        root.findAll("musicCarouselShelfRenderer").mapNotNull { shelf ->
            val items = shelf.at("contents").elements()
            val tracks = items.mapNotNull { listTrack(it.at("musicResponsiveListItemRenderer")) }
            val playlists = items.mapNotNull { playlistCard(it.at("musicTwoRowItemRenderer")) }
            val title = shelf.at("header", "musicCarouselShelfBasicHeaderRenderer", "title").text()
            if (title == null || tracks.isEmpty() && playlists.isEmpty()) null else MusicShelf(title, tracks, playlists)
        }

    // ------------------------------------------------------------------ search

    /** What a search found: the top result, the list of the rest, the filters on offer and where more can be had. */
    fun searchPage(root: JsonElement): SearchPage {
        val chips = root.findAll("chipCloudChipRenderer").mapNotNull { chip ->
            val label = chip.at("text").text() ?: return@mapNotNull null
            SearchChip(label, chip.at("navigationEndpoint", "searchEndpoint", "params").string() ?: return@mapNotNull null)
        }
        val top = root.findAll("musicCardShelfRenderer").firstOrNull()?.let { cardItem(it) }
        // The songs shown inside the card of the top result are in the list below it too, so they are left out here
        val items = root.findAll("musicResponsiveListItemRenderer", skip = "musicCardShelfRenderer").mapNotNull { searchItem(it) }
        return SearchPage(chips, top, items, root.findAll("musicShelfRenderer").firstOrNull()?.let { searchToken(it) })
    }

    /** The results after the first ones of a search. */
    fun searchMore(root: JsonElement): SearchPage {
        val shelf = root.at("continuationContents", "musicShelfContinuation")
        val items = shelf.at("contents").elements().mapNotNull { searchItem(it.at("musicResponsiveListItemRenderer")) }
        return SearchPage(emptyList(), null, items, shelf?.let { searchToken(it) })
    }

    private fun searchToken(shelf: JsonElement): String? =
        shelf.at("continuations", "0", "nextContinuationData", "continuation").string() ?: continuationToken(shelf.at("contents").elements())

    private fun searchItem(row: JsonElement?): SearchItem? {
        row ?: return null
        val columns = row.at("flexColumns").elements().map { it.at("musicResponsiveListItemFlexColumnRenderer", "text") }
        val title = columns.firstOrNull().text() ?: return null
        val byline = columns.getOrNull(1).runs()
        val thumb = row.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails").thumbnail()
        val page = row.at("navigationEndpoint", "browseEndpoint")
        page.at("browseId").string()?.let {
            return pageItem(it, page.at("browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType").string(), title, byline, thumb)
        }
        return trackItem(listTrack(row, labelled = true) ?: return null, videoType(row), byline)
    }

    /** The big card at the top of a search, which is one result like the others. */
    private fun cardItem(card: JsonElement): SearchItem? {
        val title = card.at("title").text() ?: return null
        val byline = card.at("subtitle").runs()
        val thumbs = card.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails")
        val endpoint = card.at("title").runs().firstOrNull().at("navigationEndpoint")
        endpoint.at("browseEndpoint", "browseId").string()?.let {
            val pageType = endpoint.at("browseEndpoint", "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType").string()
            return pageItem(it, pageType, title, byline, thumbs.thumbnail())
        }
        val watch = endpoint.at("watchEndpoint")
        val type = watch.at("watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string()
        val duration = byline.mapNotNull { it.at("text").string()?.trim() }.lastOrNull { DURATION.matches(it) }
        val song = track(watch.at("videoId").string() ?: return null, title, withoutLabel(byline), duration, thumbs, type)
        return trackItem(song, type, byline)
    }

    /** A result that opens a page: an artist, a profile, an album or a playlist. */
    private fun pageItem(pageId: String, pageType: String?, title: String, byline: List<JsonElement>, thumb: String?): SearchItem? {
        val label = labelOf(byline)
        val rest = groups(withoutLabel(byline)).joinToString(" · ").takeIf { it.isNotEmpty() }
        return when (pageType) {
            "MUSIC_PAGE_TYPE_ARTIST" -> SearchItem("artist", pageId, title, rest, label, thumb)
            "MUSIC_PAGE_TYPE_USER_CHANNEL" -> SearchItem("profile", pageId, title, rest, label, thumb)
            "MUSIC_PAGE_TYPE_ALBUM" -> SearchItem("album", pageId, title, rest, label, thumb)
            "MUSIC_PAGE_TYPE_PLAYLIST" -> SearchItem("playlist", pageId.removePrefix("VL"), title, rest, label, thumb)
            "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE" -> SearchItem("playlist", pageId, title, rest, label, thumb)
            else -> null
        }
    }

    /** A result that plays: a song, a video or an episode of a podcast. */
    private fun trackItem(song: MusicTrack, type: String?, byline: List<JsonElement>): SearchItem {
        val label = labelOf(byline)
        if (type != "MUSIC_VIDEO_TYPE_PODCAST_EPISODE") {
            return SearchItem(if (song.isSong) "song" else "video", song.videoId, song.title, null, label, song.thumbUrl, song)
        }
        // An episode's line is its date and its show, not an artist
        val parts = groups(withoutLabel(byline))
        val episode = song.copy(artist = parts.lastOrNull().orEmpty(), artistId = null)
        return SearchItem("episode", song.videoId, song.title, parts.joinToString(" · "), label, song.thumbUrl, episode)
    }

    private val LABELS = setOf("Song", "Video", "Episode", "Podcast", "Single", "EP", "Album", "Playlist", "Artist", "Profile")

    /** The word at the start of a line like "Single • Artist • 2014" that says what the result is, if there is one. */
    private fun labelOf(runs: List<JsonElement>): String? {
        val first = runs.firstOrNull() ?: return null
        val text = first.at("text").string()?.trim()
        val alone = runs.size == 1 || runs[1].at("text").string()?.trim() == "•"
        return text?.takeIf { it in LABELS && alone && first.at("navigationEndpoint") == null }
    }

    private fun withoutLabel(runs: List<JsonElement>): List<JsonElement> = if (labelOf(runs) != null) runs.drop(2) else runs

    /** The pieces of a line of runs between its "•" separators, each one text. */
    private fun groups(runs: List<JsonElement>): List<String> {
        val out = mutableListOf(StringBuilder())
        for (run in runs) {
            val text = run.at("text").string().orEmpty()
            if (text.trim() == "•") out.add(StringBuilder()) else out.last().append(text)
        }
        return out.map { it.toString().trim() }.filter { it.isNotEmpty() }
    }

    // ------------------------------------------------------------------ items

    /** A song of the queue list, which may come with the other release of it. */
    private fun panelTrack(item: JsonElement): MusicTrack? {
        val wrapper = item.at("playlistPanelVideoWrapperRenderer")
        if (wrapper != null) {
            val primary = panelRow(wrapper.at("primaryRenderer", "playlistPanelVideoRenderer")) ?: return null
            val other = panelRow(wrapper.at("counterpart").elements().firstOrNull().at("counterpartRenderer", "playlistPanelVideoRenderer"))
            return primary.copy(counterpart = other)
        }
        return panelRow(item.at("playlistPanelVideoRenderer"))
    }

    private fun panelRow(row: JsonElement?): MusicTrack? {
        row ?: return null
        val videoId = row.at("videoId").string() ?: return null
        val type = row.at("navigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string()
        return track(
            videoId = videoId,
            title = row.at("title").text() ?: return null,
            byline = row.at("longBylineText").runs(),
            duration = row.at("lengthText").text(),
            thumbs = row.at("thumbnail", "thumbnails"),
            type = type,
        )
    }

    /** A row of a list (search result, top songs, related), or null when the row is not a song or video. */
    private fun listTrack(row: JsonElement?, labelled: Boolean = false): MusicTrack? {
        row ?: return null
        val videoId = row.at("playlistItemData", "videoId").string()
            ?: row.at("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId").string()
            ?: return null
        val columns = row.at("flexColumns").elements().map { it.at("musicResponsiveListItemFlexColumnRenderer", "text") }
        val type = videoType(row)
        // The length is in a column of its own, or at the end of the second one
        val duration = (columns.drop(1).flatMap { it.runs() } + row.at("fixedColumns").elements().flatMap { it.at("musicResponsiveListItemFixedColumnRenderer", "text").runs() })
            .mapNotNull { it.at("text").string()?.trim() }
            .lastOrNull { DURATION.matches(it) }
        return track(
            videoId = videoId,
            title = columns.firstOrNull().text() ?: return null,
            byline = columns.getOrNull(1).runs().let { if (labelled) withoutLabel(it) else it },
            duration = duration,
            thumbs = row.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
            type = type,
        )
    }

    /** What kind of video a row plays (`MUSIC_VIDEO_TYPE_ATV` for a song), as the row says it. */
    private fun videoType(row: JsonElement): String? {
        val columns = row.at("flexColumns").elements().map { it.at("musicResponsiveListItemFlexColumnRenderer", "text") }
        return row.at("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string()
            ?: columns.firstOrNull().runs().firstOrNull().at("navigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string()
    }

    /** The parts of a line like "Artist • Album • 1987" are told apart by where the separators are. */
    private fun track(videoId: String, title: String, byline: List<JsonElement>, duration: String?, thumbs: JsonElement?, type: String?): MusicTrack {
        val parts = mutableListOf(mutableListOf<JsonElement>())
        for (run in byline) {
            if (run.at("text").string()?.trim() == "•") parts.add(mutableListOf()) else parts.last().add(run)
        }
        val artistRuns = parts.first()
        fun pageId(run: JsonElement?) = run.at("navigationEndpoint", "browseEndpoint", "browseId").string()
        val album = parts.drop(1).flatten().firstOrNull { pageId(it)?.startsWith("MPRE") == true }
        val year = parts.drop(1).lastOrNull()?.singleOrNull()?.at("text").string()?.takeIf { YEAR.matches(it) }
        // A video's line says how many watched it instead of which album it is on
        val stats = parts.drop(1).map { part -> part.joinToString("") { it.at("text").string().orEmpty() }.trim() }
            .filter { it.endsWith("views") || it.endsWith("likes") || it.endsWith("plays") }
            .joinToString(" · ").takeIf { it.isNotEmpty() }
        return MusicTrack(
            videoId = videoId,
            title = title,
            artist = artistRuns.joinToString("") { it.at("text").string().orEmpty() }.trim(),
            artistId = artistRuns.firstNotNullOfOrNull { pageId(it)?.takeIf { id -> id.startsWith("UC") } },
            album = album?.at("text").string(),
            albumId = pageId(album),
            year = year,
            durationSec = seconds(duration),
            thumbUrl = thumbs.thumbnail(),
            isSong = type == "MUSIC_VIDEO_TYPE_ATV",
            stats = stats,
        )
    }

    private fun artistCard(card: JsonElement?): ArtistCard? {
        card ?: return null
        val id = card.at("navigationEndpoint", "browseEndpoint", "browseId").string()?.takeIf { it.startsWith("UC") } ?: return null
        return ArtistCard(id, card.at("title").text().orEmpty(), card.at("subtitle").text(), card.at("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails").thumbnail())
    }

    private fun albumCard(card: JsonElement?): AlbumCard? {
        card ?: return null
        val id = card.at("navigationEndpoint", "browseEndpoint", "browseId").string()?.takeIf { it.startsWith("MPRE") } ?: return null
        return AlbumCard(id, card.at("title").text().orEmpty(), card.at("subtitle").text(), card.at("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails").thumbnail())
    }

    private fun playlistCard(card: JsonElement?): PlaylistCard? {
        card ?: return null
        val id = card.at("navigationEndpoint", "browseEndpoint", "browseId").string()?.removePrefix("VL")?.takeIf { it.startsWith("PL") || it.startsWith("RD") || it.startsWith("OLAK") } ?: return null
        return PlaylistCard(id, card.at("title").text().orEmpty(), card.at("subtitle").text(), card.at("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails").thumbnail())
    }

    /** A row of cards that scrolls sideways, whatever the cards are; null when it has no name or nothing in it. */
    private fun carousel(shelf: JsonElement): MusicShelf? {
        val title = shelf.at("header", "musicCarouselShelfBasicHeaderRenderer", "title").text() ?: return null
        val tracks = ArrayList<MusicTrack>()
        val playlists = ArrayList<PlaylistCard>()
        val albums = ArrayList<AlbumCard>()
        val artists = ArrayList<ArtistCard>()
        for (item in shelf.at("contents").elements()) {
            val card = item.at("musicTwoRowItemRenderer")
            listTrack(item.at("musicResponsiveListItemRenderer"))?.let { tracks += it }
                ?: videoCard(card)?.let { tracks += it }
                ?: artistCard(card)?.let { artists += it }
                ?: albumCard(card)?.let { albums += it }
                ?: playlistCard(card)?.let { playlists += it }
        }
        if (tracks.isEmpty() && playlists.isEmpty() && albums.isEmpty() && artists.isEmpty()) return null
        return MusicShelf(title, tracks, playlists, albums, artists)
    }

    /** A card of a video, which opens the video instead of a page. */
    private fun videoCard(card: JsonElement?): MusicTrack? {
        card ?: return null
        val watch = card.at("navigationEndpoint", "watchEndpoint")
        return track(
            videoId = watch.at("videoId").string() ?: return null,
            title = card.at("title").text() ?: return null,
            byline = card.at("subtitle").runs(),
            duration = null,
            thumbs = card.at("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
            type = watch.at("watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string(),
        )
    }

    // ------------------------------------------------------------------ reading

    private val ALBUM_KINDS = setOf("Album", "Single", "EP")

    private val DURATION = Regex("""\d{1,2}(:\d{2}){1,2}""")
    private val YEAR = Regex("""\d{4}""")
    private val SIZE = Regex("""=w\d+-h\d+""")

    /** "3:34" or "1:02:03" in seconds; 0 for anything else. */
    internal fun seconds(text: String?): Long {
        if (text == null || !DURATION.matches(text)) return 0
        return text.split(':').fold(0L) { total, part -> total * 60 + part.toLong() }
    }

    /** The biggest picture of a list, and in a size fit for a cover: YouTube serves any square size by its address. */
    private fun JsonElement?.thumbnail(): String? {
        val url = elements().maxByOrNull { it.at("width").string()?.toIntOrNull() ?: 0 }.at("url").string() ?: return null
        return if (url.contains("googleusercontent.com")) SIZE.replace(url, "=w544-h544") else url
    }

    /** The element under [path], where each step is a key of an object or a position in an array. */
    private fun JsonElement?.at(vararg path: String): JsonElement? {
        var node = this
        for (step in path) {
            node = when (node) {
                is JsonObject -> node[step]
                is JsonArray -> step.toIntOrNull()?.let { node.getOrNull(it) }
                else -> null
            } ?: return null
        }
        return node
    }

    private fun JsonElement?.string(): String? = (this as? JsonPrimitive)?.contentOrNull

    private fun JsonElement?.elements(): List<JsonElement> = (this as? JsonArray)?.toList() ?: emptyList()

    private fun JsonElement?.runs(): List<JsonElement> = at("runs").elements()

    /** The pieces of a line like "18 songs • 1 hour, 13 minutes", without the separators. */
    private fun JsonElement?.parts(): List<String> = groups(runs())

    /** The text of a run list joined, like the title of a shelf. */
    private fun JsonElement?.text(): String? =
        runs().joinToString("") { it.at("text").string().orEmpty() }.takeIf { it.isNotEmpty() }

    /** Every value under [key], wherever it is in the tree. */
    private fun JsonElement.findAll(key: String, skip: String? = null): List<JsonElement> {
        val found = ArrayList<JsonElement>()
        fun walk(node: JsonElement) {
            when (node) {
                is JsonObject -> node.forEach { (k, v) -> if (k == key) found += v else if (k != skip) walk(v) }
                is JsonArray -> node.forEach(::walk)
                else -> Unit
            }
        }
        walk(this)
        return found
    }
}
