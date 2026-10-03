package app.sapoche

import android.net.Uri

/** Cover addresses; the same rules as `sharpThumbnail` in the Flutter app. */
object Thumbnails {
    private val YOUTUBE_PATH = Regex("^/vi(?:_webp)?/([\\w-]{11})/")
    private val GOOGLE_SIZE = Regex("=w\\d+-h\\d+")

    /** The largest picture the host offers for [url]; [url] itself when it does not say. */
    fun sharp(url: String): String {
        val uri = Uri.parse(url)
        val host = uri.host ?: return url
        if (host.endsWith("ytimg.com")) {
            val id = YOUTUBE_PATH.find(uri.path ?: "")?.groupValues?.get(1)
            if (id != null) return "https://i.ytimg.com/vi/$id/maxresdefault.jpg"
        }
        if (host.endsWith("googleusercontent.com") || host.endsWith("ggpht.com")) {
            return url.replaceFirst(GOOGLE_SIZE, "=w1200-h1200")
        }
        return url
    }
}
