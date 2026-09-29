package app.unison.core

/** Picks video and playlist ids out of whatever the user pasted. */
object YoutubeLinks {
    private val videoLinks = listOf(
        Regex("""youtube\.com/watch\?(?:.*&)?v=([A-Za-z0-9_-]{11})"""),
        Regex("""youtu\.be/([A-Za-z0-9_-]{11})"""),
        Regex("""youtube\.com/(?:shorts|embed|live)/([A-Za-z0-9_-]{11})"""),
    )
    private val playlistLink = Regex("""youtube\.com/playlist\?(?:.*&)?list=([A-Za-z0-9_-]{10,})""")
    private val bareId = Regex("""[A-Za-z0-9_-]{11}""")

    /** The playlist id of a link to a playlist page. A video opened inside a playlist is just that video. */
    fun playlistId(text: String): String? = playlistLink.find(text)?.groupValues?.get(1)

    /** The video id of a video link, or of a bare id. Null for anything else, including ordinary search words. */
    fun videoId(text: String): String? {
        videoLinks.forEach { pattern -> pattern.find(text)?.let { return it.groupValues[1] } }
        // A bare id must not be an ordinary 11 letter word from a search: real ids nearly always have a digit, _ or -
        return text.takeIf { bareId.matches(it) && it.any { c -> c.isDigit() || c == '_' || c == '-' } }
    }
}
