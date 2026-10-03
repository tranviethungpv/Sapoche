package app.sapoche

import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Timestamped event log kept in memory, mirrored to logcat and to a file.
 * The file lets us pull the full history over adb after a long screen-off test. Lines reach the file
 * in batches, since a write per line keeps the storage awake for nothing.
 */
object EventLog {
    private const val MAX_LINES = 400
    private const val MAX_FILE_BYTES = 2_000_000L
    private const val BATCH_LINES = 25
    private const val BATCH_MS = 60_000L

    private val format = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val lines = ArrayDeque<String>()
    private var file: File? = null
    private val unwritten = StringBuilder()
    private var unwrittenLines = 0
    private var lastWriteMs = System.currentTimeMillis()

    val listeners = CopyOnWriteArrayList<(String) -> Unit>()

    fun init(dir: File) {
        val f = File(dir, "sapoche.log")
        if (f.exists() && f.length() > MAX_FILE_BYTES) f.delete()
        file = f
        d("log", "---- process started ----")
    }

    @Synchronized
    fun d(tag: String, message: String) {
        val line = "${format.format(Date())} [$tag] $message"
        Log.i("Sapoche", line)
        lines.addLast(line)
        if (lines.size > MAX_LINES) lines.removeFirst()
        unwritten.append(line).append('\n')
        unwrittenLines++
        if (unwrittenLines >= BATCH_LINES || System.currentTimeMillis() - lastWriteMs > BATCH_MS) flush()
        listeners.forEach { it(line) }
    }

    /** Writes what is waiting to the file; called when the app leaves the screen or the service ends. */
    @Synchronized
    fun flush() {
        if (unwrittenLines > 0) runCatching { file?.appendText(unwritten.toString()) }
        unwritten.setLength(0)
        unwrittenLines = 0
        lastWriteMs = System.currentTimeMillis()
    }

    @Synchronized
    fun snapshot(): List<String> = lines.toList()
}
