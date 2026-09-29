package app.unison

import android.os.SystemClock
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * Logs how fast bytes really arrive from the network, once per second while a transfer is active.
 * Used to find out whether the CDN, the network or the player is the bottleneck.
 */
class ThroughputLogger : TransferListener {
    private var startMs = 0L
    private var windowStartMs = 0L
    private var windowBytes = 0L
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
        windowStartMs = startMs
        windowBytes = 0
        totalBytes = 0
        EventLog.d("http", "response started (first byte after headers)")
    }

    @Synchronized
    override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
        if (!isNetwork) return
        windowBytes += bytesTransferred
        totalBytes += bytesTransferred
        val now = SystemClock.elapsedRealtime()
        if (now - windowStartMs >= 1_000) {
            val kbps = windowBytes * 8 / (now - windowStartMs)
            EventLog.d("http", "rx ${kbps}kbps, total ${totalBytes / 1024}KB after ${(now - startMs) / 1000}s")
            windowStartMs = now
            windowBytes = 0
        }
    }

    @Synchronized
    override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        if (!isNetwork) return
        EventLog.d("http", "transfer ended, total ${totalBytes / 1024}KB in ${(SystemClock.elapsedRealtime() - startMs) / 1000}s")
    }
}
