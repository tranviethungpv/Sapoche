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
        val topSongs = root.findAll("musicShelfRenderer").firstOrNull()
            .at("contents").elements().mapNotNull { listTrack(it.at("musicResponsiveListItemRenderer")) }
        val albums = ArrayList<AlbumCard>()
        val singles = ArrayList<AlbumCard>()
        val similar = ArrayList<ArtistCard>()
        for (shelf in root.findAll("musicCarouselShelfRenderer")) {
            val title = shelf.at("header", "musicCarouselShelfBasicHeaderRenderer", "title").text()
            for (item in shelf.at("contents").elements()) {
                val card = item.at("musicTwoRowItemRenderer")
                artistCard(card)?.let { similar += it } ?: albumCard(card)?.let { (if (title == "Albums") albums else if (title == "Singles & EPs") singles else null)?.add(it) }
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
        )
    }

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
    private fun listTrack(row: JsonElement?): MusicTrack? {
        row ?: return null
        val videoId = row.at("playlistItemData", "videoId").string()
            ?: row.at("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId").string()
            ?: return null
        val columns = row.at("flexColumns").elements().map { it.at("musicResponsiveListItemFlexColumnRenderer", "text") }
        val type = row.at("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string()
            ?: columns.firstOrNull().runs().firstOrNull().at("navigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType").string()
        // The length is in a column of its own, or at the end of the second one
        val duration = (columns.drop(1).flatMap { it.runs() } + row.at("fixedColumns").elements().flatMap { it.at("musicResponsiveListItemFixedColumnRenderer", "text").runs() })
            .mapNotNull { it.at("text").string()?.trim() }
            .lastOrNull { DURATION.matches(it) }
        return track(
            videoId = videoId,
            title = columns.firstOrNull().text() ?: return null,
            byline = columns.getOrNull(1).runs(),
            duration = duration,
            thumbs = row.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
            type = type,
        )
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

    // ------------------------------------------------------------------ reading

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

    /** The text of a run list joined, like the title of a shelf. */
    private fun JsonElement?.text(): String? =
        runs().joinToString("") { it.at("text").string().orEmpty() }.takeIf { it.isNotEmpty() }

    /** Every value under [key], wherever it is in the tree. */
    private fun JsonElement.findAll(key: String): List<JsonElement> {
        val found = ArrayList<JsonElement>()
        fun walk(node: JsonElement) {
            when (node) {
                is JsonObject -> node.forEach { (k, v) -> if (k == key) found += v else walk(v) }
                is JsonArray -> node.forEach(::walk)
                else -> Unit
            }
        }
        walk(this)
        return found
    }
}
