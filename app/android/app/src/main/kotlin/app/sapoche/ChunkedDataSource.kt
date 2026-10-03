package app.sapoche

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.IOException

/**
 * Reads a stream as ranges of at most [CHUNK_BYTES], one after the other, so that the reader sees one transfer.
 * YouTube's servers send a range of up to about 11 MB at full speed, but throttle a longer one, or one with no end,
 * to about real-time speed (measured 2026-10-02: 8 MB in 0.8 s, against 0.3 Mbit/s for "bytes=0-" on a long song).
 */
class ChunkedDataSource(private val upstream: DataSource) : DataSource {

    class Factory(private val upstream: DataSource.Factory) : DataSource.Factory {
        override fun createDataSource(): DataSource = ChunkedDataSource(upstream.createDataSource())
    }

    private var dataSpec: DataSpec? = null

    /** Where the next byte comes from, where the open range stops, and where the whole read stops; all in the file. */
    private var position = 0L
    private var rangeEnd = 0L
    private var end = 0L

    /** False when the server answered with the whole file whatever was asked; then it is read as it comes. */
    private var split = false

    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        this.dataSpec = dataSpec
        position = dataSpec.position
        val asked = if (dataSpec.length == C.LENGTH_UNSET.toLong()) Long.MAX_VALUE else dataSpec.position + dataSpec.length
        end = asked
        openRange()
        val total = totalLength()
        if (total == C.LENGTH_UNSET.toLong()) {
            // No range in the answer: the server does not split, so the read goes as it was asked
            split = false
            upstream.close()
            return upstream.open(dataSpec)
        }
        split = true
        end = minOf(asked, total)
        return end - dataSpec.position
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (!split) return upstream.read(buffer, offset, length)
        if (position >= end) return C.RESULT_END_OF_INPUT
        if (position >= rangeEnd) {
            upstream.close()
            openRange()
        }
        val read = upstream.read(buffer, offset, minOf(length.toLong(), rangeEnd - position).toInt())
        if (read == C.RESULT_END_OF_INPUT) {
            // The answer stopped short of the range it promised: the loader tries again from here
            throw IOException("The stream ended at byte $position of $end")
        }
        position += read
        return read
    }

    override fun getUri(): Uri? = upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

    override fun close() {
        dataSpec = null
        upstream.close()
    }

    /** Opens the range that starts at [position]. */
    private fun openRange() {
        val spec = dataSpec ?: throw IOException("Not open")
        val length = minOf(CHUNK_BYTES, end - position)
        val opened = upstream.open(spec.subrange(position - spec.position, length))
        rangeEnd = position + if (opened == C.LENGTH_UNSET.toLong()) length else opened
    }

    /** The length of the whole file, from "Content-Range: bytes 0-8388607/109839037"; unset when not given. */
    private fun totalLength(): Long {
        val header = upstream.responseHeaders.entries
            .firstOrNull { it.key.equals("Content-Range", ignoreCase = true) }
            ?.value?.firstOrNull() ?: return C.LENGTH_UNSET.toLong()
        return header.substringAfterLast('/').trim().toLongOrNull() ?: C.LENGTH_UNSET.toLong()
    }

    companion object {
        const val CHUNK_BYTES = 8L * 1024 * 1024
    }
}
