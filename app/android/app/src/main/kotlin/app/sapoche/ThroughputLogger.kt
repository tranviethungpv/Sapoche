package app.sapoche

import android.os.SystemClock
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * Logs when a network transfer starts and ends, with the bytes and time it took. Used to find out
 * whether the CDN, the network or the player is the bottleneck. Not per second: each line is a write.
 */
class ThroughputLogger : TransferListener {
    private var startMs = 0L
    private var totalBytes = 0L

    @Synchronized
    override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        if (!isNetwork) return
        EventLog.d("http", "request position=${dataSpec.position} length=${dataSpec.length}")
    }

    @Synchronized
    override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        if (!isNetwork) return
        startMs = SystemClock.elapsedRealtime()
        totalBytes = 0
        EventLog.d("http", "response started (first byte after headers)")
    }

    @Synchronized
    override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
        if (!isNetwork) return
        totalBytes += bytesTransferred
    }

    @Synchronized
    override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        if (!isNetwork) return
        EventLog.d("http", "transfer ended, total ${totalBytes / 1024}KB in ${(SystemClock.elapsedRealtime() - startMs) / 1000}s")
    }
}
