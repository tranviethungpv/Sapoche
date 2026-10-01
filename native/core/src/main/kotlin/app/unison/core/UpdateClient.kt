package app.unison.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

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
) {
    fun isNewerThan(installedCode: Long) = versionCode > installedCode
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
     */
    suspend fun download(release: Release, file: File, onProgress: (Long) -> Unit = {}) = withContext(Dispatchers.IO) {
        file.parentFile?.mkdirs()
        if (file.length() > release.size) file.delete()
        if (file.length() < release.size) fetch(release, file, onProgress)
        if (file.length() != release.size || sha256(file) != release.sha256) {
            file.delete()
            throw IOException("the downloaded file does not match the release")
        }
        onProgress(release.size)
    }

    private suspend fun fetch(release: Release, file: File, onProgress: (Long) -> Unit) {
        val have = file.length()
        val call = request(release.file) { if (have > 0) header("Range", "bytes=$have-") }
        client.newCall(call).execute().use { response ->
            // 200 to a Range request: the server started over, so the old part is of no use
            val resumed = response.code == 206 && have > 0
            if (response.code == 416) file.delete()
            if (response.code == 404) throw IOException("release ${release.versionCode} is not on the server")
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
                    if (done - lastReport >= release.size / 100) {
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
