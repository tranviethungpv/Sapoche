package app.sapoche.core

import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The reader of a `player` answer against one YouTube really gave (cut short, shared with the Swift tests). */
class InnertubePlayerTest {

    private fun fixture(name: String) = checkNotNull(javaClass.getResource("/player/$name.json")) { "missing $name" }.readText()

    private fun parse(text: String) = InnertubePlayer.parse(Json.parseToJsonElement(text), "dQw4w9WgXcQ")

    /** The fixture without [field] in every stream. */
    private fun without(text: String, field: String): String {
        val root = Json.parseToJsonElement(text) as JsonObject
        fun strip(node: JsonElement): JsonElement = when (node) {
            is JsonObject -> JsonObject(node.filterKeys { it != field }.mapValues { strip(it.value) })
            is JsonArray -> JsonArray(node.map(::strip))
            else -> node
        }
        return strip(root).toString()
    }

    @Test
    fun `an answer gives the song, the audio streams best first and the picture streams tallest first`() {
        val resolved = parse(fixture("player_visionos"))
        assertEquals("Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)", resolved.track.title)
        assertEquals("Rick Astley", resolved.track.artist)
        assertEquals(213, resolved.track.durationSec)
        assertNotNull(resolved.track.thumbUrl)
        assertEquals(setOf(140, 251, 250, 249, 139), resolved.all.map { it.itag }.toSet())
        assertEquals(resolved.all.map { it.bitrateKbps }.sortedDescending(), resolved.all.map { it.bitrateKbps })
        assertEquals(140, resolved.best.itag, "the best bitrate wins, the AAC one over the Opus of the same size")
        assertEquals("M4A", resolved.best.codec)
        assertEquals(setOf("M4A", "WEBMA_OPUS"), resolved.all.map { it.codec }.toSet())
        assertTrue(resolved.best.contentLength > 0)
        assertEquals("visionos", resolved.via)
        val heights = resolved.videos.map { it.height }
        assertEquals(heights.sortedDescending(), heights)
        assertTrue(resolved.videos.any { it.format == "MPEG_4" && it.codec.startsWith("avc1") })
        assertTrue(resolved.videos.any { it.format == "WEBM" })
    }

    @Test
    fun `each stream carries how loud the song is`() {
        assertEquals(6.55, assertNotNull(parse(fixture("player_visionos_loud")).best.loudnessDb), 0.001)
        assertEquals(0.99, assertNotNull(parse(fixture("player_visionos")).best.loudnessDb), 0.001)
    }

    @Test
    fun `without a loudness of its own a stream takes the one of the whole song against the reference level`() {
        val loud = parse(without(fixture("player_visionos_loud"), "loudnessDb"))
        assertEquals(6.55, assertNotNull(loud.best.loudnessDb), 0.001, "-7.45 LKFS against the target of -14")
        val unknown = parse(without(without(fixture("player_visionos_loud"), "loudnessDb"), "perceptualLoudnessDb"))
        assertNull(unknown.best.loudnessDb)
    }

    @Test
    fun `an answer that refuses says why`() {
        val refused = Json.parseToJsonElement("""{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you're not a bot"}}""")
        assertEquals("Sign in to confirm you're not a bot", assertFailsWith<InnertubeRefused> { InnertubePlayer.parse(refused, "x") }.message)
        val noReason = Json.parseToJsonElement("""{"playabilityStatus":{"status":"ERROR"}}""")
        assertTrue(assertFailsWith<InnertubeRefused> { InnertubePlayer.parse(noReason, "x") }.message!!.contains("ERROR"))
    }

    @Test
    fun `a live stream and a video without sound are refused`() {
        val live = Json.parseToJsonElement("""{"playabilityStatus":{"status":"OK"},"videoDetails":{"isLive":true,"lengthSeconds":"0"}}""")
        assertFailsWith<InnertubeRefused> { InnertubePlayer.parse(live, "x") }
        val silent = Json.parseToJsonElement(
            """{"playabilityStatus":{"status":"OK"},"videoDetails":{"lengthSeconds":"60"},"streamingData":{"adaptiveFormats":[
               {"itag":137,"url":"https://example.invalid/v","mimeType":"video/mp4; codecs=\"avc1.640028\"","height":1080}]}}""",
        )
        assertFailsWith<InnertubeRefused> { InnertubePlayer.parse(silent, "x") }
    }

    @Test
    fun `a dubbed track is not the song`() {
        val text = """{"playabilityStatus":{"status":"OK"},"videoDetails":{"lengthSeconds":"60"},"streamingData":{"adaptiveFormats":[
            {"itag":140,"url":"https://example.invalid/a","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","averageBitrate":129000,"audioTrack":{"audioIsDefault":false}},
            {"itag":139,"url":"https://example.invalid/b","mimeType":"audio/mp4; codecs=\"mp4a.40.5\"","averageBitrate":48000,"audioTrack":{"audioIsDefault":true}}]}}"""
        assertEquals(listOf(139), parse(text).all.map { it.itag })
    }

    @Test
    fun `resolving asks as the visionOS app with a visitor identity`() = runTest {
        val sent = ArrayList<Triple<String, Map<String, String>, String>>()
        val transport = InnertubeTransport { endpoint, headers, body ->
            sent += Triple(endpoint, headers, body)
            if (endpoint == "visitor_id") """{"responseContext":{"visitorData":"VISITOR1"}}""" else fixture("player_visionos")
        }
        val resolved = InnertubePlayer(region = { "VN" }, transport = transport).resolve("dQw4w9WgXcQ")
        assertEquals(140, resolved.best.itag)
        assertEquals(listOf("visitor_id", "player"), sent.map { it.first })
        val (_, headers, body) = sent.last()
        assertEquals("VISITOR1", headers["X-Goog-Visitor-Id"])
        assertEquals("101", headers["X-YouTube-Client-Name"])
        assertTrue(headers["User-Agent"]!!.startsWith("com.google.visionos.youtube/"))
        val json = Json.parseToJsonElement(body) as JsonObject
        val client = (json["context"] as JsonObject)["client"] as JsonObject
        assertEquals(JsonPrimitive("VISIONOS"), client["clientName"])
        assertEquals(JsonPrimitive("VISITOR1"), client["visitorData"])
        assertEquals(JsonPrimitive("VN"), client["gl"])
        assertEquals(JsonPrimitive("dQw4w9WgXcQ"), json["videoId"])
    }

    private class Scripted(private val players: List<String>) : InnertubeTransport {
        val sent = ArrayList<Pair<String, Map<String, String>>>()
        private var identities = 0
        private var asked = 0
        override suspend fun post(endpoint: String, headers: Map<String, String>, body: String): String {
            sent += endpoint to headers
            return if (endpoint == "visitor_id") """{"responseContext":{"visitorData":"V${++identities}"}}""" else players[minOf(asked++, players.size - 1)]
        }
    }

    private val botCheck = """{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you're not a bot"}}"""

    @Test
    fun `an identity asked for in advance is given out once, and a new one is asked for after it`() = runTest {
        var clock = 0L
        var asked = 0
        val source = object : VisitorSource {
            override suspend fun take() = fresh()
            override suspend fun fresh() = "V${++asked}"
        }
        val visitors = PrefetchedVisitors(source, backgroundScope, { clock })
        runCurrent()
        assertEquals("V1", visitors.take())
        runCurrent()
        assertEquals("V2", visitors.take(), "the one asked for after the first was taken")
        runCurrent()
        clock += 11 * 60 * 1000L
        assertEquals("V4", visitors.take(), "V3 waited too long and is not used")
    }

    @Test
    fun `a failed ask for an identity in advance leaves the next song to ask for its own`() = runTest {
        var asked = 0
        val source = object : VisitorSource {
            override suspend fun take() = fresh()
            override suspend fun fresh(): String = if (++asked == 1) throw java.io.IOException("offline") else "V$asked"
        }
        val visitors = PrefetchedVisitors(source, backgroundScope)
        runCurrent()
        assertEquals("V2", visitors.take())
    }

    @Test
    fun `an identity that went stale gets the bot check and the video is asked for again with a new one`() = runTest {
        val transport = Scripted(listOf(botCheck, fixture("player_visionos")))
        val player = InnertubePlayer(transport = transport, visitors = PrefetchedVisitors(FreshVisitors(transport = transport), backgroundScope))
        runCurrent()
        val resolved = player.resolve("dQw4w9WgXcQ")
        assertEquals(140, resolved.best.itag)
        val players = transport.sent.filter { it.first == "player" }
        assertEquals(2, players.size)
        assertEquals("V1", players[0].second["X-Goog-Visitor-Id"])
        assertTrue(players[1].second["X-Goog-Visitor-Id"] != "V1", "the retry does not use the identity that was turned down")
    }

    @Test
    fun `a bot check on a new identity is not asked again`() = runTest {
        val transport = Scripted(listOf(botCheck))
        val player = InnertubePlayer(transport = transport)
        assertFailsWith<InnertubeRefused> { player.resolve("dQw4w9WgXcQ") }
        assertEquals(1, transport.sent.count { it.first == "player" })
    }
}
