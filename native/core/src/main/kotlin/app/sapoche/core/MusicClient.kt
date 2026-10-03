package app.sapoche.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

/** Sends a request to YouTube Music and gives back the answer text. */
fun interface MusicTransport {
    suspend fun post(endpoint: String, body: String): String
}

/**
 * YouTube Music as the website asks it, for a person who is not signed in: this is what gives radios, the
 * related page, lyrics and artists, which NewPipeExtractor does not. It is not a documented API and can
 * change, so the readers in [MusicParser] give what they find and callers treat failure as "nothing to show".
 */
class MusicClient(
    /** The country whose music is shown first, as a code like "VN"; follows the phone. */
    private val region: () -> String = { "US" },
    private val transport: MusicTransport = OkHttpTransport(),
) : MusicSource {

    override suspend fun watchNext(videoId: String, radio: Boolean): WatchNext = MusicParser.watchNext(
        ask("next") {
            put("videoId", videoId)
            put("isAudioOnly", true)
            if (radio) put("playlistId", "RDAMVM$videoId")
        },
    )

    override suspend fun related(relatedId: String): Related = MusicParser.related(browse(relatedId))

    override suspend fun lyrics(lyricsId: String): String? = MusicParser.lyrics(browse(lyricsId))

    override suspend fun artist(artistId: String): ArtistPage = MusicParser.artist(artistId, browse(artistId))

    override suspend fun collection(id: String): CollectionPage =
        MusicParser.collection(id, browse(if (id.startsWith("MPRE") || id.startsWith("MPSP") || id.startsWith("VL")) id else "VL$id"))

    override suspend fun more(token: String): Continuation = MusicParser.continuation(ask("browse") { put("continuation", token) })

    override suspend fun searchPage(query: String, params: String?): SearchPage = MusicParser.searchPage(
        ask("search") {
            put("query", query)
            if (params != null) put("params", params)
        },
    )

    override suspend fun searchMore(token: String): SearchPage = MusicParser.searchMore(ask("search") { put("continuation", token) })

    override suspend fun searchSongs(query: String): List<MusicTrack> = MusicParser.search(search(query, SONGS))

    override suspend fun searchVideos(query: String): List<MusicTrack> = MusicParser.search(search(query, VIDEOS))

    // Only the shelf names of this page are meant to be read by a person; everything else is found by the words
    // YouTube Music uses in English ("Lyrics", "Related"), so those calls stay in English
    override suspend fun trending(language: String): List<MusicShelf> =
        MusicParser.shelves(ask("browse", language) { put("browseId", "FEmusic_home") })

    private suspend fun browse(id: String) = ask("browse") { put("browseId", id) }

    private suspend fun search(query: String, filter: String) = ask("search") {
        put("query", query)
        put("params", filter)
    }

    private suspend fun ask(endpoint: String, language: String = "en", fields: JsonObjectBuilder.() -> Unit): JsonElement {
        val body = buildJsonObject {
            put(
                "context",
                buildJsonObject {
                    put(
                        "client",
                        buildJsonObject {
                            put("clientName", CLIENT_NAME)
                            put("clientVersion", CLIENT_VERSION)
                            put("hl", language)
                            put("gl", region().ifBlank { "US" })
                        },
                    )
                },
            )
            fields()
        }
        return Json.parseToJsonElement(transport.post(endpoint, body.toString()))
    }

    companion object {
        const val CLIENT_NAME = "WEB_REMIX"

        /** The version of the website the answers are shaped for; YouTube Music stops answering very old ones. */
        const val CLIENT_VERSION = "1.20250310.01.00"

        /** The search filters of the website's "Songs" and "Videos" chips. */
        private const val SONGS = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
        private const val VIDEOS = "EgWKAQIQAWoKEAkQBRAKEAMQBA=="
    }
}

class OkHttpTransport(private val client: OkHttpClient = OkHttpDownloader.defaultClient()) : MusicTransport {
    override suspend fun post(endpoint: String, body: String): String = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url("https://music.youtube.com/youtubei/v1/$endpoint?prettyPrint=false")
            .header("Origin", "https://music.youtube.com")
            .header("User-Agent", OkHttpDownloader.USER_AGENT)
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("YouTube Music answered ${response.code}")
            response.body.string()
        }
    }
}
