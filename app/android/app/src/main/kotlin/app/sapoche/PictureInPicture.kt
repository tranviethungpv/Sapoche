package app.sapoche

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import android.view.WindowManager
import androidx.annotation.RequiresApi

/**
 * The picture in a small window over other apps, and the screen kept on while somebody watches it. The UI says when
 * the picture is watched; leaving the app then moves it into the small window, on phones that have one. In the small
 * window the system shows the controls of the media session: play, pause, previous and next.
 */
class PictureInPicture(private val activity: Activity) {

    val supported: Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /** The picture is on screen and playing. */
    private var watching = false

    /** The shape of the last picture, for the small window. */
    private var aspect = DEFAULT_ASPECT

    val active: Boolean get() = activity.isInPictureInPictureMode

    fun setWatching(on: Boolean, width: Int, height: Int) {
        watching = on
        if (width > 0 && height > 0) aspect = fit(width, height)
        // A video plays: the screen must not go dark under it, as it would for music
        if (on) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && supported) {
            runCatching { activity.setPictureInPictureParams(params()) }
                .onFailure { EventLog.d("video", "small window settings refused: ${it.message}") }
        }
    }

    /** Opens the small window now; false where the phone has none or refuses it (turned off in its settings). */
    fun enter(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !supported) return false
        return runCatching { activity.enterPictureInPictureMode(params()) }
            .onFailure { EventLog.d("video", "small window refused: ${it.message}") }
            .getOrDefault(false)
    }

    /** The person leaves the app (home, another app). From Android 12 the system opens the small window by itself. */
    fun onUserLeaveHint() {
        if (watching && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enter()
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun params(): PictureInPictureParams = PictureInPictureParams.Builder()
        .setAspectRatio(aspect)
        .apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setAutoEnterEnabled(watching)
                setSeamlessResizeEnabled(true)
            }
        }
        .build()

    companion object {
        private val DEFAULT_ASPECT = Rational(16, 9)

        /** Android refuses a small window more than 2.39 times as wide as it is tall, or the other way round. */
        private const val MOST = 2.39

        /** The shape of a [width] x [height] picture, within what the small window can take. */
        fun fit(width: Int, height: Int): Rational {
            val ratio = width.toDouble() / height
            return when {
                ratio > MOST -> Rational(239, 100)
                ratio < 1 / MOST -> Rational(100, 239)
                else -> Rational(width, height)
            }
        }
    }
}
