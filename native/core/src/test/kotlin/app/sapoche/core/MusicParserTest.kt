package app.sapoche.core

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
    fun `an artist has videos and playlists too, and says where all of the top songs are`() = runTest {
        val page = client("browse" to "artist_full").artist("UC3muIvzjhubNpJ4Pn_0kCQw")
        assertEquals("OLAK5uy_kq6u7GZbsa9TKcZQc6HQWPsKsFjQenbmA", page.topSongsId)
        assertTrue(page.similar.isNotEmpty(), "fans might also like")
        val videos = page.shelves.first { it.title == "Videos" }.tracks.first()
        assertEquals("FN7ALfpGxiI", videos.videoId)
        assertEquals("Nơi này có anh", videos.title)
        assertEquals("Sơn Tùng M-TP", videos.artist)
        assertEquals("461M views", videos.stats)
        assertFalse(videos.isSong)
        assertTrue(page.shelves.any { it.title == "Live performances" })
        assertTrue(page.shelves.none { it.title == "Albums" || it.title == "Fans might also like" }, "those have places of their own")
    }

    @Test
    fun `a profile has videos and playlists and no songs of its own`() = runTest {
        val page = client("browse" to "profile").artist("UC3KdrjbFKLRbobhTLIJPQHQ")
        assertEquals("Tran Nam SKY", page.name)
        assertEquals("1.91K", page.subscribers)
        assertTrue(page.topSongs.isEmpty())
        assertTrue(page.albums.isEmpty())
        assertEquals(listOf("Videos", "Playlists"), page.shelves.map { it.title })
        assertTrue(page.shelves.last().playlists.isNotEmpty())
    }

    @Test
    fun `an album has its facts, its songs with the artist filled in and rows to go on to`() = runTest {
        val asked = mutableListOf<String>()
        val music = MusicClient { _, body ->
            asked += body
            fixture("album")
        }
        val page = music.collection("MPREb_rL78Ovsej32")
        assertTrue(asked.single().contains("""browseId":"MPREb_rL78Ovsej32"""), "an album is asked for by its own id")
        assertEquals("m-tp M-TP", page.title)
        assertEquals("Album", page.kind)
        assertEquals("2017", page.year)
        assertEquals("Sơn Tùng M-TP", page.owner)
        assertEquals("UC3muIvzjhubNpJ4Pn_0kCQw", page.ownerId)
        assertEquals(listOf("18 songs", "1 hour, 13 minutes"), page.stats)
        assertNotNull(page.description)
        assertNotNull(page.thumbUrl)
        assertNull(page.more, "an album comes whole")
        val first = page.tracks.first()
        assertEquals("JQwLF3fsGY0", first.videoId)
        assertEquals("Cơn Mưa Ngang Qua", first.title)
        assertEquals("Sơn Tùng M-TP", first.artist)
        assertEquals("UC3muIvzjhubNpJ4Pn_0kCQw", first.artistId)
        assertEquals("m-tp M-TP", first.album)
        assertEquals("MPREb_rL78Ovsej32", first.albumId)
        assertEquals(235, first.durationSec)
        assertTrue(first.isSong)
        assertEquals(page.thumbUrl, first.thumbUrl, "the rows of an album have no picture, so they take the cover of the album")
        assertTrue(page.shelves.first().albums.isNotEmpty())
    }

    @Test
    fun `a playlist is asked for by its id with VL in front, and says who made it`() = runTest {
        val asked = mutableListOf<String>()
        val music = MusicClient { _, body ->
            asked += body
            fixture("playlist")
        }
        val page = music.collection("PLrALqIYcGkySSOHxefqyordgqMgiQHW8P")
        assertTrue(asked.single().contains("""browseId":"VLPLrALqIYcGkySSOHxefqyordgqMgiQHW8P"""))
        assertEquals("Playlist", page.kind)
        assertEquals("2026", page.year)
        assertEquals("Sensual Musique", page.owner)
        assertEquals(listOf("5M views", "1,818 tracks", "155+ hours"), page.stats)
        assertEquals("The kid in blue, Alberto Ciccarini - Even If You Don't Call (Lyrics)", page.tracks.first().title)
        assertEquals("Sensual Musique", page.tracks.first().artist)
        assertFalse(page.tracks.first().isSong)
        assertNull(page.tracks.first().album, "a playlist does not say which album its songs are on")
        assertNotNull(page.more, "a playlist of 1,818 songs comes a hundred at a time")
    }

    @Test
    fun `the next songs of a playlist come with where the ones after them are`() = runTest {
        val asked = mutableListOf<String>()
        val music = MusicClient { _, body ->
            asked += body
            fixture("playlist_more")
        }
        val next = music.more("TOKEN")
        assertTrue(asked.single().contains("""continuation":"TOKEN"""))
        assertEquals(5, next.tracks.size)
        assertNotNull(next.more)
    }

    @Test
    fun `a search lists what YouTube Music finds, a top result and the filters on offer`() = runTest {
        val page = client("search" to "search_top_song").searchPage("never gonna give you up", null)
        // YouTube puts first the kind that suits the search best, so the order is its own
        assertEquals("Videos", page.chips.first().label)
        assertEquals(
            setOf("Artists", "Albums", "Songs", "Videos", "Community playlists", "Featured playlists", "Profiles", "Episodes", "Podcasts"),
            page.chips.map { it.label }.toSet(),
        )
        // The tail of the code changes with the search, so only its start is the same
        assertTrue(page.chips.first { it.label == "Songs" }.params.startsWith("EgWKAQII"))
        val top = assertNotNull(page.top)
        assertEquals("video", top.kind)
        assertEquals("dQw4w9WgXcQ", top.id)
        assertEquals("Never Gonna Give You Up", top.title)
        assertEquals("Video", top.label)
        assertEquals("Rick Astley", top.track?.artist)
        // The videos listed inside the card of the top result are not repeated: the list starts after them
        assertEquals("song", page.items.first().kind)
        val song = page.items.first()
        assertEquals("lYBUbBu4W08", song.id)
        assertEquals("Song", song.label)
        assertEquals("Rick Astley", song.track?.artist, "the label is not the artist")
        assertTrue(song.track?.isSong == true)
        val single = page.items.first { it.kind == "album" }
        assertEquals("MPREb_noEixV4hNb8", single.id)
        assertEquals("Single", single.label)
        assertEquals("Caleb Hyles · 2023", single.subtitle)
    }

    @Test
    fun `the top result of a search can be an artist`() = runTest {
        val top = assertNotNull(client("search" to "search_top_artist").searchPage("taylor swift", null).top)
        assertEquals("artist", top.kind)
        assertEquals("UCPC0L1d253x-KuMNwa05TpA", top.id)
        assertEquals("Taylor Swift", top.title)
        assertEquals("444M monthly audience", top.subtitle)
    }

    @Test
    fun `a search for one kind sends its filter and gives that kind`() = runTest {
        val asked = mutableListOf<String>()
        val music = MusicClient { _, body ->
            asked += body
            fixture("search_artists")
        }
        val page = music.searchPage("son tung mtp", "FILTER")
        assertTrue(asked.single().contains("""params":"FILTER"""))
        assertNull(page.top)
        assertTrue(page.items.all { it.kind == "artist" })
        val first = page.items.first()
        assertEquals("UC3muIvzjhubNpJ4Pn_0kCQw", first.id)
        assertEquals("Sơn Tùng M-TP", first.title)
        assertEquals("10.8M monthly audience", first.subtitle)
        assertNotNull(first.thumbUrl)
    }

    @Test
    fun `without a filter the search is not sent one`() = runTest {
        val asked = mutableListOf<String>()
        MusicClient { _, body ->
            asked += body
            fixture("search_top_song")
        }.searchPage("x", null)
        assertFalse(asked.single().contains("params"))
    }

    @Test
    fun `albums, playlists, profiles and episodes each open or play what they are`() = runTest {
        val albums = client("search" to "search_albums").searchPage("q", "A").items
        assertTrue(albums.all { it.kind == "album" && it.id.startsWith("MPRE") })
        assertEquals("Em Của Ngày Hôm Qua", albums.first().title)
        assertEquals("Single", albums.first().label)
        assertEquals("Sơn Tùng M-TP · 2014", albums.first().subtitle)

        val playlists = client("search" to "search_playlists").searchPage("q", "P")
        val list = playlists.items.first()
        assertEquals("playlist", list.kind)
        assertEquals("PL0NlNYU99BSMfNcGaEWqBWAh7vOtSzUid", list.id, "the VL of the page is not part of the id of the playlist")
        assertEquals("Mùa Đi Ngang Phố · 291K views", list.subtitle)
        assertNotNull(playlists.more, "there are more playlists to ask for")

        val profile = client("search" to "search_profiles").searchPage("q", "P").items.first()
        assertEquals("profile", profile.kind)
        assertEquals("UC3KdrjbFKLRbobhTLIJPQHQ", profile.id)
        assertEquals("@trannam_sky", profile.subtitle)

        val episode = client("search" to "search_episodes").searchPage("q", "E").items.first()
        assertEquals("episode", episode.kind)
        assertEquals("elsqDQZDuMA", episode.id)
        assertTrue(episode.subtitle!!.startsWith("Sep 6"))
        assertTrue(episode.track!!.artist.isNotEmpty() && !episode.track!!.artist.startsWith("Sep"), "the show, not the date")
    }

    @Test
    fun `the results after the first ones come with where the ones after them are`() = runTest {
        val asked = mutableListOf<String>()
        val music = MusicClient { _, body ->
            asked += body
            fixture("search_more")
        }
        val next = music.searchMore("TOKEN")
        assertTrue(asked.single().contains("""continuation":"TOKEN"""))
        assertTrue(next.items.isNotEmpty())
        assertTrue(next.chips.isEmpty())
        assertNull(next.top)
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

    @Test
    fun `only the home page is asked for in the language of the person, everything else in English`() = runTest {
        val bodies = mutableListOf<String>()
        val client = MusicClient(region = { "VN" }) { _, body ->
            bodies += body
            """{}"""
        }
        client.watchNext("x")
        client.lyrics("x")
        client.searchSongs("x")
        client.trending("vi")
        fun field(body: String, name: String) = Regex("\"$name\":\"(\\w+)\"").find(body)?.groupValues?.get(1)
        // The readers find lyrics and related songs by the English names of their tabs, so these must not change
        assertTrue(bodies.dropLast(1).all { field(it, "hl") == "en" }, bodies.toString())
        assertEquals("vi", field(bodies.last(), "hl"))
        // The country only decides what is shown first, never the words
        assertTrue(bodies.all { field(it, "gl") == "VN" })
    }

    @Test
    fun `a missing country falls back to the United States`() = runTest {
        var body = ""
        MusicClient(region = { "" }) { _, sent ->
            body = sent
            """{}"""
        }.searchVideos("x")
        assertTrue(body.contains("\"gl\":\"US\""))
    }
}
