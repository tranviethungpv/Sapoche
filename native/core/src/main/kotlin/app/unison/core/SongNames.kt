package app.unison.core

/** Titles and artists as people type them on YouTube, brought closer to what a song is called. */
object SongNames {
    /** Words that describe a recording or a video of it, not the song: "(Official Video)", "[Lyrics]", "(Remastered 2009)". */
    private val NOISE = Regex(
        """official|video|audio|lyric|visuali[sz]er|\bm/?v\b|\bhd\b|\bhq\b|\b4k\b|remaster|\bclip\b|full (song|album)|\bfeat\b|\bft\b""",
        RegexOption.IGNORE_CASE,
    )
    private val BRACKETS = Regex("""\s*[(\[][^)\]]*[)\]]""")
    private val ARTIST_SPLIT = Regex("""\s*(?:,|&|\bx\b|\bfeat\.?|\bft\.?|\bvà\b|\band\b)\s*""", RegexOption.IGNORE_CASE)
    private val CHANNEL_SUFFIX = Regex("""\s*(?:-\s*topic|vevo|official(?:\s+channel)?)$""", RegexOption.IGNORE_CASE)

    /**
     * The title without bracketed tags that only describe the recording. "Remix", "Live" and "Acoustic" stay:
     * they are other recordings. With [artist], a leading "Artist - " is dropped too.
     */
    fun title(raw: String, artist: String? = null): String {
        var text = BRACKETS.replace(raw) { if (NOISE.containsMatchIn(it.value)) "" else it.value }.trim()
        val dash = text.indexOf(" - ")
        if (dash > 0 && artist != null && artist(artist).let { main -> main.isNotEmpty() && text.substring(0, dash).contains(main, ignoreCase = true) }) {
            text = text.substring(dash + 3).trim()
        }
        return text.ifEmpty { raw.trim() }
    }

    /** The first artist of a credit like "A, B & C", without "- Topic", "VEVO" or "Official". */
    fun artist(raw: String): String {
        val first = ARTIST_SPLIT.split(CHANNEL_SUFFIX.replace(raw.trim(), "")).first()
        return CHANNEL_SUFFIX.replace(first, "").trim()
    }
}
