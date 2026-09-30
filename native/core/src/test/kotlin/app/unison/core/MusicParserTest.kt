package app.unison.core

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The readers against answers YouTube Music really gave (cut short), so a change of shape shows up here. */
class MusicParserTest {

    private fun fixture(name: String) = checkNotNull(javaClass.getResource("/music/$name.json")) { "missing $name" }.readText()

    private fun client(vararg answers: Pair<String, String>): MusicClient {
        val byEndpoint = answers.toMap()
        return MusicClient { endpoint, _ -> fixture(byEndpoint.getValue(endpoint)) }
    }

    @Test
    fun `the radio of a song starts with it and knows it is a song`() = runTest {
        val next = client("next" to "next_song").watchNext("lYBUbBu4W08")
        val first = next.tracks.first()
        assertEquals("lYBUbBu4W08", first.videoId)
        assertEquals("Never Gonna Give You Up", first.title)
        assertEquals("Rick Astley", first.artist)
        assertEquals("UCwZEU0wAwIyZb4x5G_KJp2w", first.artistId)
        assertEquals("Whenever You Need Somebody", first.album)
        assertEquals("1987", first.year)
        assertEquals(214, first.durationSec)
        assertNull(first.stats)
        assertTrue(first.isSong)
        assertTrue(next.tracks.drop(1).all { it.isSong }, "the radio of a song is made of songs")
        assertNotNull(next.lyricsId)
        assertNotNull(next.relatedId)
    }

    @Test
    fun `the radio of a video is made of videos`() = runTest {
        val next = client("next" to "next_video").watchNext("dQw4w9WgXcQ")
        val first = next.tracks.first()
        assertEquals("dQw4w9WgXcQ", first.videoId)
        assertFalse(first.isSong)
        assertEquals("Rick Astley", first.artist, "the views and likes that follow are not part of the artist")
        assertNull(first.album)
        assertNull(first.year)
        assertEquals("1.8B views · 19M likes", first.stats)
    }

    @Test
    fun `a cover is asked for at a size fit for the player`() = runTest {
        val first = client("next" to "next_song").watchNext("lYBUbBu4W08").tracks.first()
        assertTrue(first.thumbUrl!!.contains("=w544-h544"), first.thumbUrl)
    }

    @Test
    fun `the related page has songs, other performances, artists and playlists`() = runTest {
        val related = client("browse" to "related").related("MPTRt_x")
        assertTrue(related.more.isNotEmpty())
        assertEquals("QAo_Ycocl1E", related.more.first().videoId)
        assertTrue(related.artists.isNotEmpty())
        assertTrue(related.artists.first().id.startsWith("UC"))
        assertTrue(related.playlists.isNotEmpty())
        assertTrue(related.otherPerformances.isNotEmpty())
        assertTrue(related.about!!.startsWith("Richard Paul Astley"))
    }

    @Test
    fun `lyrics come as plain text`() = runTest {
        val words = client("browse" to "lyrics").lyrics("MPLYt_x")
        assertTrue(words!!.startsWith("We're no strangers to love"))
    }

    @Test
    fun `an artist has a picture, a bio, top songs and releases`() = runTest {
        val artist = client("browse" to "artist").artist("UCwZEU0wAwIyZb4x5G_KJp2w")
        assertEquals("Rick Astley", artist.name)
        assertTrue(artist.description!!.startsWith("Richard Paul Astley"))
        assertEquals("4.55M", artist.subscribers?.substringBefore(' '))
        assertNotNull(artist.thumbUrl)
        assertTrue(artist.topSongs.isNotEmpty())
        assertTrue(artist.albums.isNotEmpty())
        assertTrue(artist.albums.all { it.id.startsWith("MPRE") })
        assertTrue(artist.singles.isNotEmpty())
        assertTrue(artist.similar.isNotEmpty())
    }

    @Test
    fun `a search for songs gives songs and one for videos gives videos`() = runTest {
        val songs = client("search" to "search_songs").searchSongs("chung ta cua hien tai")
        assertEquals("Chúng Ta Của Hiện Tại", songs.first().title)
        assertEquals("Sơn Tùng M-TP", songs.first().artist)
        assertEquals(302, songs.first().durationSec)
        assertTrue(songs.all { it.isSong })

        val videos = client("search" to "search_videos").searchVideos("chung ta cua hien tai")
        assertTrue(videos.isNotEmpty())
        assertTrue(videos.none { it.isSong })
        assertTrue(videos.all { it.durationSec > 0 })
    }

    @Test
    fun `the home page has shelves of songs or playlists`() = runTest {
        val shelves = client("browse" to "home").trending()
        assertTrue(shelves.isNotEmpty())
        assertTrue(shelves.all { it.title.isNotBlank() && (it.tracks.isNotEmpty() || it.playlists.isNotEmpty()) })
        assertTrue(shelves.flatMap { it.playlists }.all { it.id.isNotBlank() })
    }

    @Test
    fun `an answer of a shape that is not known gives nothing instead of failing`() = runTest {
        val client = MusicClient { _, _ -> """{"unexpected":[1,2,{"a":null}]}""" }
        assertEquals(emptyList(), client.watchNext("x").tracks)
        assertNull(client.lyrics("x"))
        assertEquals(emptyList(), client.searchSongs("x"))
        assertEquals("", client.artist("UC").name)
        assertEquals(emptyList(), client.trending())
    }

    @Test
    fun `the other release is read when YouTube names it`() = runTest {
        fun row(id: String, title: String, length: String, type: String) = """
            {"videoId":"$id","title":{"runs":[{"text":"$title"}]},"longBylineText":{"runs":[{"text":"A"}]},
             "lengthText":{"runs":[{"text":"$length"}]},
             "navigationEndpoint":{"watchEndpoint":{"watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"$type"}}}}}
        """
        val answer = """
            {"contents":{"singleColumnMusicWatchNextResultsRenderer":{"tabbedRenderer":{"watchNextTabbedResultsRenderer":{"tabs":[
              {"tabRenderer":{"content":{"musicQueueRenderer":{"content":{"playlistPanelRenderer":{"contents":[
                {"playlistPanelVideoWrapperRenderer":{
                  "primaryRenderer":{"playlistPanelVideoRenderer":${row("song1", "T", "3:00", "MUSIC_VIDEO_TYPE_ATV")}},
                  "counterpart":[{"counterpartRenderer":{"playlistPanelVideoRenderer":${row("clip1", "T (Official Video)", "3:20", "MUSIC_VIDEO_TYPE_OMV")}}}]}}
              ]}}}}}}
            ]}}}}}
        """
        val track = MusicClient { _, _ -> answer }.watchNext("song1").tracks.single()
        assertTrue(track.isSong)
        assertEquals("clip1", track.counterpart?.videoId)
        assertFalse(track.counterpart!!.isSong)
        assertEquals(200, track.counterpart!!.durationSec)
    }

    @Test
    fun `lengths are read in minutes and hours`() {
        assertEquals(214, MusicParser.seconds("3:34"))
        assertEquals(3723, MusicParser.seconds("1:02:03"))
        assertEquals(0, MusicParser.seconds("710K views"))
        assertEquals(0, MusicParser.seconds(null))
    }
}
