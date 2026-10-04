package app.sapoche

import androidx.media3.common.C
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import app.sapoche.sync.LoadFailure

/**
 * Keeps retrying network failures for minutes instead of a few seconds. With a large buffer the
 * player still has audio to play while the loader waits for the network, so a short outage must not
 * surface as a playback error that throws that audio away.
 *
 * A rejected stream URL (expired, or bound to an address the device no longer has) will not fix
 * itself: those fail at once so the caller can resolve a fresh URL. So does a stream that could not be
 * had at all: [StreamCache] has made its own tries by then, and the player's owner decides what is next.
 */
class PatientLoadErrorPolicy : DefaultLoadErrorHandlingPolicy() {

    override fun getMinimumLoadableRetryCount(dataType: Int): Int = MAX_RETRIES

    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
        val error = loadErrorInfo.exception
        if (error is HttpDataSource.InvalidResponseCodeException && error.responseCode in URL_REJECTED_CODES) {
            return C.TIME_UNSET
        }
        if (generateSequence<Throwable>(error) { it.cause }.take(8).any { it is LoadFailure || it is StreamCache.ResolveFailed }) {
            return C.TIME_UNSET
        }
        return super.getRetryDelayMsFor(loadErrorInfo)
    }

    private companion object {
        /** About eight minutes at the default 5 second retry delay. */
        const val MAX_RETRIES = 100
        val URL_REJECTED_CODES = setOf(401, 403, 404, 410)
    }
}
