package app.unison

import android.app.Activity
import android.os.Build
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup

/**
 * Asks Android for the display's fastest refresh rate while the screen is moving. A Flutter app does not ask for
 * anything, so from Android 15 on the system gives it its "normal" rate (60 Hz on a phone that can do 120) as soon as a
 * finger lets go, and the sheet that settles after a drag, a fling or a page change is shown at half of what the
 * display can do. The UI tells when frames come one after another ([smooth]); when they stop, the request is taken
 * back so that a still screen does not hold the display at its fastest.
 */
class SmoothDisplay(private val activity: Activity) {

    private var on = false

    /** The fastest rate of the display's modes that keep the screen's size. */
    private val fastest: Float
        get() {
            val display = activity.display ?: return 0f
            val mode = display.mode
            return display.supportedModes
                .filter { it.physicalWidth == mode.physicalWidth && it.physicalHeight == mode.physicalHeight }
                .maxOfOrNull { it.refreshRate } ?: mode.refreshRate
        }

    fun smooth(wanted: Boolean) {
        if (wanted == on) return
        on = wanted
        apply()
    }

    /** The surface can be made again (the app came back to the front), and the request has to be made on the new one. */
    fun reapply() {
        if (on) apply()
    }

    private fun apply() {
        val rate = if (on) fastest else 0f
        if (Build.VERSION.SDK_INT >= 30) {
            surfaces(activity.window.decorView).forEach { surface ->
                if (surface.isValid) {
                    // 0 takes the request back; the system then decides by itself again
                    if (Build.VERSION.SDK_INT >= 31) {
                        surface.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT, Surface.CHANGE_FRAME_RATE_ALWAYS)
                    } else {
                        surface.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
                    }
                }
            }
        } else {
            // Before Android 11 the only way is a preference of the window
            val attributes = activity.window.attributes
            attributes.preferredRefreshRate = rate
            activity.window.attributes = attributes
        }
        EventLog.d("display", if (on) "asking for ${rate.toInt()} Hz" else "back to the system's choice")
    }

    /** Every surface of the screen: Flutter draws on one, the video picture is another. */
    private fun surfaces(view: View): List<Surface> = when (view) {
        is SurfaceView -> listOf(view.holder.surface)
        is ViewGroup -> (0 until view.childCount).flatMap { surfaces(view.getChildAt(it)) }
        else -> emptyList()
    }
}
