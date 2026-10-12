package app.sapoche.sync

import kotlin.math.abs

/** A music file found on this phone, as the scan reports it. [key] says where it is, and does not change while it stays there. */
data class LocalFile(
    val key: String,
    val uri: String,
    val title: String,
    val artist: String,
    val album: String,
    val durMs: Long,
    val mime: String,
    val size: Long,
    val addedAt: Long,
)

/** A music file the library already knows, with whether anything (a like, a playlist, a listen) points to its song. */
data class KnownLocal(
    val id: String,
    val key: String,
    val title: String,
    val artist: String,
    val durMs: Long,
    val referenced: Boolean,
)

/** What a scan changes: [files] are written under their ids, [missing] are kept but marked as gone, [forget] are dropped. */
data class LocalPlan(val files: List<Pair<String, LocalFile>>, val missing: List<String>, val forget: List<String>)

object LocalMusic {
    const val PREFIX = "local:"

    /** Where the picture of a local song is asked for: `thumb` of a song that has a file on this phone. */
    const val COVER_PREFIX = "sapoche-local:"

    /** A song shorter than this is not music (a voice message, a ringtone): the same length that counts a song as heard. */
    const val MIN_MS = 30_000L

    /** Two lengths this far apart still are the same song. */
    const val SAME_LENGTH_MS = 2_000L

    fun isLocal(videoId: String) = videoId.startsWith(PREFIX)

    fun cover(videoId: String) = COVER_PREFIX + videoId

    /**
     * The id of a song for the file at [key]: `local:` and 16 hexadecimal digits (FNV-1a, 64 bits). The colon is why it
     * can never be the id of a YouTube video, and why a room, whose server wants those, never takes it. [attempt] > 0
     * makes another id for the same key, for the rare file whose first id is taken.
     */
    fun id(key: String, attempt: Int = 0): String {
        var hash = 0xcbf29ce484222325UL.toLong() // the FNV offset basis
        val bytes = (if (attempt == 0) key else "$key#$attempt").toByteArray(Charsets.UTF_8)
        for (byte in bytes) {
            hash = (hash xor (byte.toLong() and 0xff)) * 0x100000001b3L
        }
        return PREFIX + java.lang.Long.toHexString(hash).padStart(16, '0')
    }

    /**
     * Works out what to do with what a scan [found] given what is [known]. A file is known by where it is; a new one that
     * is the only one that looks like the single file that went missing (same title and artist, almost the same length)
     * is that file, moved, and takes its song over so likes and playlists stay; with several candidates nothing is joined.
     */
    fun plan(found: List<LocalFile>, known: List<KnownLocal>): LocalPlan {
        val byKey = known.associateBy { it.key }
        val seen = HashSet<String>()
        val unmatched = ArrayList<LocalFile>()
        val files = ArrayList<Pair<String, LocalFile>>()
        for (file in found) {
            val existing = byKey[file.key]
            if (existing == null) unmatched += file else if (seen.add(existing.id)) files += existing.id to file
        }
        val gone = known.filter { it.id !in seen }.toMutableList()
        val taken = HashSet<String>().apply { addAll(known.map { it.id }) }
        for (file in unmatched) {
            val twins = gone.filter { same(it, file) }
            val twin = twins.singleOrNull()?.takeIf { candidate -> unmatched.count { same(candidate, it) } == 1 }
            if (twin != null) {
                gone.remove(twin)
                seen += twin.id
                files += twin.id to file
                continue
            }
            var attempt = 0
            var id = id(file.key)
            while (id in taken) id = id(file.key, ++attempt)
            taken += id
            files += id to file
        }
        val (still, forgotten) = gone.partition { it.referenced }
        return LocalPlan(files, still.map { it.id }, forgotten.map { it.id })
    }

    private fun same(known: KnownLocal, file: LocalFile) =
        norm(known.title) == norm(file.title) && norm(known.artist) == norm(file.artist) &&
            abs(known.durMs - file.durMs) <= SAME_LENGTH_MS

    private fun norm(text: String) = text.trim().lowercase().replace(Regex("\\s+"), " ")
}
