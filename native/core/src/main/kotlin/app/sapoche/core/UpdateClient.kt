package app.sapoche.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream

/** One release of the app as the server describes it (`latest.json`). */
data class Release(
    val versionCode: Long,
    val versionName: String,
    val sha256: String,
    val size: Long,
    val notes: String,
    /** Name of the apk on the server; the first versions of the server only had `app-<versionCode>.apk`. */
    val file: String = "app-$versionCode.apk",
    /** The notes in Vietnamese, when there are any. */
    val notesVi: String = "",
    /** The notes of the last few versions, newest first: what a phone several versions behind has missed. */
    val history: List<ReleaseNote> = emptyList(),
    /** The same apk gzipped (a third smaller to fetch), and its size; empty when the server has none. */
    val gzFile: String = "",
    val gzSize: Long = 0,
) {
    fun isNewerThan(installedCode: Long) = versionCode > installedCode

    /**
     * What there is to read of the versions newer than [installed] (`1.27.0`, no build number), newest first. A server
     * that sends no history still has the notes of this release.
     */
    fun notesAfter(installed: String): List<ReleaseNote> =
        (history.ifEmpty { listOf(ReleaseNote(versionName, notes, notesVi)) })
            .filter { ReleaseNote.compare(it.version, installed) > 0 }
            .sortedWith { a, b -> ReleaseNote.compare(b.version, a.version) }
}

/** What changed in one version, in English and, when there are any, in Vietnamese. */
data class ReleaseNote(val version: String, val notes: String, val notesVi: String = "") {
    companion object {
        /** Orders `1.9.0` before `1.10.0`: part by part, as numbers; a part that is not a number counts as 0. */
        fun compare(a: String, b: String): Int {
            val x = a.split('.').map { it.toIntOrNull() ?: 0 }
            val y = b.split('.').map { it.toIntOrNull() ?: 0 }
            for (i in 0 until maxOf(x.size, y.size)) {
                val c = x.getOrElse(i) { 0 }.compareTo(y.getOrElse(i) { 0 })
                if (c != 0) return c
            }
            return 0
        }
    }
}

/**
 * Asks the server which release is the newest and fetches it. The file comes from a private bucket (see
 * server/src/update.ts), so every call carries the room key in [headers].
 */
class UpdateClient(
    private val baseUrl: String,
    private val headers: Map<String, String>,
    private val client: OkHttpClient = OkHttpClient.Builder().callTimeout(0, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).build(),
) {

    /** The newest release, or null when nothing was published yet. */
    suspend fun latest(): Release? = withContext(Dispatchers.IO) {
        client.newCall(request("latest.json")).execute().use { response ->
            if (response.code == 404) return@use null
            if (!response.isSuccessful) throw IOException("update info: HTTP ${response.code}")
            parse(response.body.string())
        }
    }

    /**
     * Downloads [release] into [file], going on from what an earlier try left there. The result is only
     * kept when it has the announced size and checksum; a wrong file is deleted rather than offered for install.
     * The gzipped copy is fetched when the server has one and unpacked here; if that fails the plain file is fetched.
     */
    suspend fun download(release: Release, file: File, onProgress: (Long) -> Unit = {}) = withContext(Dispatchers.IO) {
        file.parentFile?.mkdirs()
        if (file.length() > release.size) file.delete()
        if (file.length() < release.size && release.gzFile.isNotEmpty() && release.gzSize > 0) {
            try {
                fetchGzipped(release, file, onProgress)
            } catch (e: IOException) {
                file.delete()
            }
        }
        if (file.length() < release.size) fetch(release.file, file, release.size, onProgress)
        if (file.length() != release.size || sha256(file) != release.sha256) {
            file.delete()
            throw IOException("the downloaded file does not match the release")
        }
        onProgress(release.size)
    }

    /** The gzipped copy goes next to [file], is unpacked into it and removed; progress counts in bytes of the apk. */
    private suspend fun fetchGzipped(release: Release, file: File, onProgress: (Long) -> Unit) {
        val gz = File(file.path + ".gz")
        if (gz.length() > release.gzSize) gz.delete()
        if (gz.length() < release.gzSize) {
            fetch(release.gzFile, gz, release.gzSize) { done -> onProgress(done * release.size / release.gzSize) }
        }
        if (gz.length() != release.gzSize) {
            gz.delete()
            throw IOException("the gzipped file is not the announced size")
        }
        try {
            GZIPInputStream(gz.inputStream(), BUFFER).use { input -> file.outputStream().use { input.copyTo(it, BUFFER) } }
        } catch (e: IOException) {
            file.delete()
            throw e
        } finally {
            gz.delete()
        }
    }

    private suspend fun fetch(name: String, file: File, size: Long, onProgress: (Long) -> Unit) {
        val have = file.length()
        val call = request(name) { if (have > 0) header("Range", "bytes=$have-") }
        client.newCall(call).execute().use { response ->
            // 200 to a Range request: the server started over, so the old part is of no use
            val resumed = response.code == 206 && have > 0
            if (response.code == 416) file.delete()
            if (response.code == 404) throw IOException("$name is not on the server")
            if (!response.isSuccessful) throw IOException("download: HTTP ${response.code}")
            RandomAccessFile(file, "rw").use { out ->
                if (resumed) out.seek(have) else out.setLength(0)
                var done = if (resumed) have else 0L
                val buffer = ByteArray(BUFFER)
                val input = response.body.byteStream()
                var lastReport = 0L
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val n = input.read(buffer)
                    if (n < 0) break
                    out.write(buffer, 0, n)
                    done += n
                    // About a hundred reports in all, not one per buffer
                    if (done - lastReport >= size / 100) {
                        lastReport = done
                        onProgress(done)
                    }
                }
            }
        }
    }

    private fun request(name: String, more: Request.Builder.() -> Unit = {}): Request =
        Request.Builder().url("${baseUrl.trimEnd('/')}/update/$name").also { builder ->
            headers.forEach { (key, value) -> builder.header(key, value) }
            builder.more()
        }.build()

    companion object {
        private const val BUFFER = 64 * 1024

        fun parse(text: String): Release {
            val json = Json.parseToJsonElement(text).jsonObject
            fun text(key: String) = json[key]?.jsonPrimitive?.contentOrNull ?: throw IOException("update info has no $key")
            return Release(
                versionCode = json["versionCode"]?.jsonPrimitive?.long ?: throw IOException("update info has no versionCode"),
                versionName = text("versionName"),
                sha256 = text("sha256").lowercase(),
                size = json["size"]?.jsonPrimitive?.long ?: throw IOException("update info has no size"),
                notes = json["notes"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                notesVi = json["notesVi"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                history = (json["history"] as? JsonArray).orEmpty().mapNotNull { item ->
                    val entry = item as? JsonObject ?: return@mapNotNull null
                    val version = entry["version"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                    ReleaseNote(
                        version,
                        entry["notes"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        entry["notesVi"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    )
                },
                gzFile = json["gzFile"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                gzSize = json["gzSize"]?.jsonPrimitive?.long ?: 0,
                file = json["file"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() } ?: "app-${json["versionCode"]?.jsonPrimitive?.long}.apk",
            )
        }

        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(BUFFER)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
