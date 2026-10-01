package app.unison.core

import kotlinx.coroutines.test.runTest
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class UpdateClientTest {

    private val apk = ByteArray(300_000) { (it * 31 % 251).toByte() }
    private lateinit var dir: File
    private lateinit var server: MockWebServer

    /** What the server does with a request for the apk; the tests swap it. */
    private var serveApk: (RecordedRequest) -> MockResponse = ::honest
    private var latestBody: String? = null
    private val seen = mutableListOf<RecordedRequest>()

    private fun release(sha: String = UpdateClient.sha256(file(apk)), size: Long = apk.size.toLong()) =
        Release(versionCode = 7, versionName = "1.3.0", sha256 = sha, size = size, notes = "")

    private fun file(bytes: ByteArray) = File(dir, "src.bin").also { it.writeBytes(bytes) }

    /** A server that answers like the real one: the whole file, or the part a Range asks for. */
    private fun honest(request: RecordedRequest): MockResponse {
        val from = request.headers["Range"]?.removePrefix("bytes=")?.removeSuffix("-")?.toInt()
        return if (from == null) {
            MockResponse.Builder().code(200).body(Buffer().write(apk)).build()
        } else {
            MockResponse.Builder().code(206).body(Buffer().write(apk, from, apk.size - from)).build()
        }
    }

    @BeforeTest
    fun start() {
        dir = Files.createTempDirectory("update-test").toFile()
        server = MockWebServer().also {
            it.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    seen += request
                    return when (request.url.encodedPath) {
                        "/update/latest.json" -> latestBody?.let { MockResponse.Builder().body(it).build() } ?: MockResponse.Builder().code(404).build()
                        "/update/app-7.apk" -> serveApk(request)
                        else -> MockResponse.Builder().code(404).build()
                    }
                }
            }
            it.start()
        }
    }

    @AfterTest
    fun stop() {
        server.close()
        dir.deleteRecursively()
    }

    private fun client() = UpdateClient(server.url("/").toString(), mapOf("X-Unison-Key" to "k"))

    @Test
    fun `the newest release is read and the key is sent`() = runTest {
        latestBody = """{"versionCode":7,"versionName":"1.3.0","sha256":"ABC","size":12,"notes":"faster"}"""
        val found = client().latest()
        assertEquals(Release(7, "1.3.0", "abc", 12, "faster"), found)
        assertEquals("k", seen.single().headers["X-Unison-Key"])
    }

    @Test
    fun `nothing published is not an error`() = runTest {
        assertNull(client().latest())
    }

    @Test
    fun `a release is only offered to an older app`() {
        assertTrue(release().isNewerThan(6))
        assertFalse(release().isNewerThan(7))
        assertFalse(release().isNewerThan(8))
    }

    @Test
    fun `info without a build number is refused`() = runTest {
        latestBody = """{"versionName":"1.3.0","sha256":"a","size":1}"""
        assertFailsWith<IOException> { client().latest() }
    }

    @Test
    fun `the whole file is downloaded and checked`() = runTest {
        val target = File(dir, "app-7.apk.part")
        val progress = mutableListOf<Long>()
        client().download(release(), target) { progress += it }
        assertTrue(target.readBytes().contentEquals(apk))
        assertEquals(apk.size.toLong(), progress.last())
        assertTrue(progress.zipWithNext().all { (a, b) -> b >= a })
    }

    @Test
    fun `a download that broke off goes on from where it stopped`() = runTest {
        val target = File(dir, "app-7.apk.part")
        target.writeBytes(apk.copyOf(120_000))
        client().download(release(), target)
        assertTrue(target.readBytes().contentEquals(apk))
        assertEquals("bytes=120000-", seen.last { it.url.encodedPath.endsWith(".apk") }.headers["Range"])
    }

    @Test
    fun `a server that ignores the range starts the file over`() = runTest {
        serveApk = { MockResponse.Builder().code(200).body(Buffer().write(apk)).build() }
        val target = File(dir, "app-7.apk.part")
        target.writeBytes(ByteArray(50_000) { 1 })
        client().download(release(), target)
        assertTrue(target.readBytes().contentEquals(apk))
    }

    @Test
    fun `a file that is already complete is only checked`() = runTest {
        val target = File(dir, "app-7.apk.part")
        target.writeBytes(apk)
        client().download(release(), target)
        assertTrue(seen.none { it.url.encodedPath.endsWith(".apk") })
    }

    @Test
    fun `a file with the wrong checksum is deleted`() = runTest {
        val target = File(dir, "app-7.apk.part")
        assertFailsWith<IOException> { client().download(release(sha = "0".repeat(64)), target) }
        assertFalse(target.exists())
    }

    @Test
    fun `a part longer than the release is thrown away`() = runTest {
        val target = File(dir, "app-7.apk.part")
        target.writeBytes(ByteArray(apk.size + 10))
        client().download(release(), target)
        assertTrue(target.readBytes().contentEquals(apk))
    }

    @Test
    fun `a release missing from the server is reported`() = runTest {
        serveApk = { MockResponse.Builder().code(404).build() }
        assertFailsWith<IOException> { client().download(release(), File(dir, "p")) }
    }
}
