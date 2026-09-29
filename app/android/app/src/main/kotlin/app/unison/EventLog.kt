package app.unison

import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Timestamped event log kept in memory, mirrored to logcat and to a file.
 * The file lets us pull the full history over adb after a long screen-off test.
 */
object EventLog {
    private const val MAX_LINES = 400
    private const val MAX_FILE_BYTES = 2_000_000L

    private val format = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val lines = ArrayDeque<String>()
    private var file: File? = null

    val listeners = CopyOnWriteArrayList<(String) -> Unit>()

    fun init(dir: File) {
        val f = File(dir, "unison.log")
        if (f.exists() && f.length() > MAX_FILE_BYTES) f.delete()
        file = f
        d("log", "---- process started ----")
    }

    @Synchronized
    fun d(tag: String, message: String) {
        val line = "${format.format(Date())} [$tag] $message"
        Log.i("Unison", line)
        lines.addLast(line)
        if (lines.size > MAX_LINES) lines.removeFirst()
        runCatching { file?.appendText(line + "\n") }
        listeners.forEach { it(line) }
    }

    @Synchronized
    fun snapshot(): List<String> = lines.toList()
}
